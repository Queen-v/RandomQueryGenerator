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

package GenTest::XML::Report;

require Exporter;
@ISA = qw(GenTest);

use strict;
use GenTest;
use GenTest::XML::BuildInfo;
use GenTest::XML::Environment;

#
# Those names are taken from Vemundo's specification for a 
# test result XML report. Not all of them will be used
#

use constant XMLREPORT_DATE			=> 0;
use constant XMLREPORT_BUILDINFO		=> 1;
use constant XMLREPORT_TESTS			=> 2;
use constant XMLREPORT_ENVIRONMENT		=> 3;

1;

sub new {
	my $class = shift;

	my $report = $class->SUPER::new({
		environment	=> XMLREPORT_ENVIRONMENT,
		date		=> XMLREPORT_DATE,
		buildinfo	=> XMLREPORT_BUILDINFO,
		tests		=> XMLREPORT_TESTS
	}, @_);

	$report->[XMLREPORT_DATE] = xml_timestamp() if not defined $report->[XMLREPORT_DATE];
	$report->[XMLREPORT_ENVIRONMENT] = GenTest::XML::Environment->new() if not defined  $report->[XMLREPORT_ENVIRONMENT];

	return $report;
}

sub xml {
	my $report = shift;

	require XML::Writer;

	my $report_xml;

	my $writer = XML::Writer->new(
		OUTPUT		=> \$report_xml,
		UNSAFE		=> 1
	);

	$writer->xmlDecl('ISO-8859-1');
	$writer->startTag('report',
		'xmlns'			=> "http://clustra.norway.sun.com/intraweb/organization/qa/cassiopeia",
		'xmlns:xsi'		=> "http://www.w3.org/2001/XMLSchema-instance",
		'xsi:schemaLocation'	=> "http://clustra.norway.sun.com/intraweb/organization/qa/cassiopeia http://clustra.norway.sun.com/intraweb/organization/qa/cassiopeia/cassiopeia-testresult.xsd"
	);
	
	$writer->dataElement('date', $report->[XMLREPORT_DATE]);
	$writer->dataElement('version', 1);
	$writer->dataElement('operator', $<);

	$writer->raw($report->[XMLREPORT_BUILDINFO]->xml()) if defined $report->[XMLREPORT_BUILDINFO];
	$writer->raw($report->[XMLREPORT_ENVIRONMENT]->xml()) if defined $report->[XMLREPORT_BUILDINFO];

	$writer->startTag('testsuites');
	$writer->startTag('testsuite', id => 0);
	$writer->dataElement('name', 'Random Query Generator');
	$writer->dataElement('environment_id', 0);
	$writer->dataElement('starttime', $report->[XMLREPORT_DATE]);
	$writer->dataElement('endtime', xml_timestamp());
	$writer->dataElement('description', 'http://forge.mysql.com/wiki/RQG');
	$writer->startTag('tests');

	foreach my $test (@{$report->[XMLREPORT_TESTS]}) {
		$writer->raw($test->xml());
	}

	$writer->endTag('tests');
	$writer->endTag('testsuite');
	$writer->endTag('testsuites');
	$writer->endTag('report');

	$writer->end();

	return $report_xml;
}

1;
