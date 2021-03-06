# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

package GenTest::Reporter::Recovery;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use GenTest::Comparator;
use Data::Dumper;
use IPC::Open2;
use IPC::Open3;

my $first_reporter;

sub monitor {
	my $reporter = shift;

	# In case of two servers, we will be called twice.
	# Only kill the first server and ignore the second call.
	
	$first_reporter = $reporter if not defined $first_reporter;
	return STATUS_OK if $reporter ne $first_reporter;

	my $pid = $reporter->serverInfo('pid');

	if (time() > $reporter->testEnd() - 19) {
		say("Sending SIGKILL to server with pid $pid in order to force a recovery.");
		kill(9, $pid);
		return STATUS_SERVER_KILLED;
	} else {
		return STATUS_OK;
	}
}

sub report {
	my $reporter = shift;

	#
	# If there is a hang during recovery in one engine, another engine may continue to print
	# periodic diagnostic output forever. This prevents PB2 timeout mechanisms from kicking in
	# In order to avoid that, we set our own crude alarm as a stop-gap measure
	#
	alarm(3600);

	$first_reporter = $reporter if not defined $first_reporter;
	return STATUS_OK if $reporter ne $first_reporter;

	my $binary = $reporter->serverInfo('binary');
	my $language = $reporter->serverVariable('language');
	my $lc_messages_dir = $reporter->serverVariable('lc_messages_dir');
	my $datadir = $reporter->serverVariable('datadir');
	$datadir =~ s{[\\/]$}{}sgio;
	my $recovery_datadir = $datadir.'_recovery';
	my $socket = $reporter->serverVariable('socket');
	my $port = $reporter->serverVariable('port');
	my $pid = $reporter->serverInfo('pid');
	my $maria_block_size = $reporter->serverVariable('maria_block_size');
	my $plugin_dir = $reporter->serverVariable('plugin_dir');
	my $plugins = $reporter->serverPlugins();

	my $engine = $reporter->serverVariable('storage_engine');

	my $dbh_prev = DBI->connect($reporter->dsn());
	if (defined $dbh_prev) {
		# Server is still running, kill it.
		$dbh_prev->disconnect();
		say("Sending SIGKILL to server with pid $pid in order to force a recovery.");
		kill(9, $pid);
		sleep(10);
	}

	system("cp -r $datadir $recovery_datadir");
	system("rm -f $recovery_datadir/core*");	# Remove cores from any previous crash
	
	say("Attempting database recovery...");

	my @mysqld_options = (
		'--no-defaults',
		'--core-file',
		'--loose-console',
		'--loose-maria-block-size='.$maria_block_size,
		'--loose-falcon-debug-mask=65019',
		'--loose-skip-falcon-support-xa',
		'--language='.$language,
		'--loose-lc-messages-dir='.$lc_messages_dir,
		'--datadir="'.$recovery_datadir.'"',
		'--log-output=file',
		'--log="'.$recovery_datadir.'/query.log"',
		'--datadir="'.$recovery_datadir.'"',
		'--socket="'.$socket.'"',
		'--port='.$port,
		'--loose-plugin-dir='.$plugin_dir,

	);

	foreach my $plugin (@$plugins) {
		push @mysqld_options, '--plugin-load='.$plugin->[0].'='.$plugin->[1];
	};

	my $mysqld_command = $binary.' '.join(' ', @mysqld_options).' 2>&1';
	say("Executing $mysqld_command .");

	my $mysqld_pid = open2(\*RDRFH, \*WTRFH, $mysqld_command);

	#
	# Phase1 - the server is running single-threaded. We consume the error log and parse it for
	# statements that indicate failed recovery
	# 

	my $recovery_status = STATUS_OK;
	while (<RDRFH>) {
		$_ =~ s{[\r\n]}{}siog;
		say($_);
		if ($_ =~ m{registration as a STORAGE ENGINE failed.}sio) {
			say("Storage engine registration failed");
			$recovery_status = STATUS_DATABASE_CORRUPTION;
		} elsif ($_ =~ m{corrupt}) {
			say("Log message '$_' indicates database corruption");
			$recovery_status = STATUS_DATABASE_CORRUPTION;
#		} elsif ($_ =~ m{exception}sio) {
#			# Wlad says ignore all exceptions, Feb 18th, 2009
#			$recovery_status = STATUS_DATABASE_CORRUPTION;
		} elsif ($_ =~ m{ready for connections}sio) {
			say("Server Recovery was apparently successfull.") if $recovery_status == STATUS_OK ;
			last;
		} elsif ($_ =~ m{device full error}sio) {
			$recovery_status = STATUS_ENVIRONMENT_FAILURE;
			last;
		} elsif (
			($_ =~ m{got signal}sio) ||
			($_ =~ m{segfault}sio) ||
			($_ =~ m{segmentation fault}sio)
		) {
			say("Recovery has apparently crashed.");
			$recovery_status = STATUS_DATABASE_CORRUPTION;
		}
	}

	my $dbh = DBI->connect($reporter->dsn());
	$recovery_status = STATUS_DATABASE_CORRUPTION if not defined $dbh && $recovery_status == STATUS_OK;

	if ($recovery_status > STATUS_OK) {
		say("Recovery has failed.");
		return $recovery_status;
	}
	
	# 
	# Phase 2 - server is now running, so we execute various statements in order to verify table consistency
	# However, while we do that, we are still responsible for processing the error log and dumping it to our stdout.
	# If we do not do that, and the server calls flish(stdout) , it will hang waiting for us to consume its stdout, which
	# we would no longer be doing. So, we call eater(), which forks a separate process to read the log and dump it to stdout.
	#

	say("Testing database consistency");

	my $eater_pid = eater(*RDRFH);

	my $databases = $dbh->selectcol_arrayref("SHOW DATABASES");
	foreach my $database (@$databases) {
		next if lc($database) eq 'mysql' || lc($database) eq 'information_schema' || lc($database) eq 'pbxt';
		$dbh->do("USE $database");
		my $tables = $dbh->selectcol_arrayref("SHOW TABLES");
		foreach my $table (@$tables) {
			say("Verifying table: $table; database: $database");

			my $sth_keys = $dbh->prepare("
				SHOW KEYS FROM `$database`.`$table`
			");

			$sth_keys->execute();

			my @predicates = ("/* no extra predicate */");

			while (my $key_hashref = $sth_keys->fetchrow_hashref()) {
				my $key_name = $key_hashref->{Key_name};
				my $column_name = $key_hashref->{Column_name};

#				push @predicates, "FORCE INDEX ($key_name) ORDER BY `$column_name` LIMIT 4294836225";

				my $main_predicate;
				if ($column_name =~ m{int}sio) {
					$main_predicate = "WHERE `$column_name` >= -9223372036854775808";
				} elsif ($column_name =~ m{char}sio) {
					$main_predicate = "WHERE `$column_name` >= ''";
				} elsif ($column_name =~ m{date}sio) {
					$main_predicate = "WHERE `$column_name` >= '1900-01-01'";
				} elsif ($column_name =~ m{time}sio) {
					$main_predicate = "WHERE `$column_name` >= '-838:59:59'";
				} else {
					next;
				}
	
				if ($key_hashref->{Null} eq 'YES') {
					$main_predicate = $main_predicate." OR `$column_name` IS NULL";
				}
		
				push @predicates, "FORCE INDEX ($key_name) ".$main_predicate;
                        };

			my %rows;
			my %data;

			foreach my $predicate (@predicates) {
				my $rows_statement = "SELECT * FROM `$database`.`$table` $predicate";
				my $sth_rows = $dbh->prepare($rows_statement);
				$sth_rows->execute();

				if (defined $sth_rows->err()) {
					say("Failing query is $rows_statement.");
					return STATUS_RECOVERY_FAILURE;
				}

				my $rows = $sth_rows->rows();
				$sth_rows->finish();

				push @{$rows{$rows}} , $predicate;
			}

			if (keys %rows > 1) {
				say("Table `$database`.`$table` is inconsistent.");
				print Dumper \%rows;

				my @rows_sorted = grep { $_ > 0 } sort keys %rows;
			
				my $least_sql = "SELECT LPAD(`pk`, 8, ' ') FROM `$database`.`$table` ".$rows{$rows_sorted[0]}->[0];
				my $most_sql  = "SELECT LPAD(`pk`, 8, ' ') FROM `$database`.`$table` ".$rows{$rows_sorted[$#rows_sorted]}->[0];
			
				say("Query that returned least rows: $least_sql\n");
				say("Query that returned most rows: $most_sql\n");
	
				my $least_result_obj = GenTest::Result->new(
					data => $dbh->selectall_arrayref($least_sql)
				);
				
				my $most_result_obj = GenTest::Result->new(
					data => $dbh->selectall_arrayref($most_sql)
				);

				say(GenTest::Comparator::dumpDiff($least_result_obj, $most_result_obj));

				$recovery_status = STATUS_DATABASE_CORRUPTION;
			}

			if (lc($engine) ne 'falcon') {
				foreach my $sql (
					"CHECK TABLE `$database`.`$table` EXTENDED",
					"ANALYZE TABLE `$database`.`$table`",
					"OPTIMIZE TABLE `$database`.`$table`",
					"REPAIR TABLE `$database`.`$table` EXTENDED",
					"ALTER TABLE `$database`.`$table` ENGINE = $engine"
				) {
					say("Executing $sql.");
					my $sth = $dbh->prepare($sql);
					if (defined $sth) {
						$sth->execute();

						return STATUS_DATABASE_CORRUPTION if $dbh->err() > 0 && $dbh->err() != 1178;
						if ($sth->{NUM_OF_FIELDS} > 0) {
							my $result = Dumper($sth->fetchall_arrayref());
							print $result;
							next if $result =~ m{is not BASE TABLE}sio;	# Do not process VIEWs
							return STATUS_DATABASE_CORRUPTION if $result =~ m{error|corrupt|repaired|invalid|crashed}sio;
						};

						$sth->finish();
					} else {
						say("Prepare failed: ".$dbh->errrstr());
						return STATUS_DATABASE_CORRUPTION;
					}
				}
			}
		}
	}

#	$reporter->shutdown($dbh);

	close(MYSQLD);

	if ($recovery_status > STATUS_OK) {
		say("Recovery has failed.");
		return $recovery_status;
	} elsif ($reporter->serverVariable('falcon_error_inject') ne '') {
		return STATUS_SERVER_KILLED;
	} else {
		return STATUS_OK;
	}
}

sub shutdown {
	my ($reporter, $dbh) = @_;
	say("Shutting down the recovered server.");

	if (not defined $dbh) {
		return STATUS_DATABASE_CORRUPTION;
	} else {
		$dbh->func('shutdown', 'admin');
		return STATUS_OK;
	}
}

sub eater {
	my $fh = shift;
	if (my $eater_pid = fork()) {
		# parent
		return $eater_pid;
	} else {
		# child
		$0 = 'Recovery log eater';
		while (<$fh>) {
			$_ =~ s{[\r\n]}{}siog;
			say($_);
		}

		exit(0);
	}
}

sub type {
	return REPORTER_TYPE_ALWAYS | REPORTER_TYPE_PERIODIC;
}

1;
