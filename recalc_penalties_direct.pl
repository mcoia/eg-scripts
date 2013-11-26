#!/usr/bin/perl

# Copyright 2011 Traverse Area District Library
# Author: Jeff Godin

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
# 

# Script to do a mass re-calculation of system standing penalies 
# Useful for updating penalties after policy/config changes
#

# An example query to fetch patron IDs to re-calculate
# 
# -- select patron ids who have a PATRON_EXCEEDS_FINES penalty
# -- with relevant home_ou and whose fines are now acceptable
# 
# select au.id from actor.usr as au 
# join actor.usr_standing_penalty as ausp on (ausp.usr = au.id)
# left join money.materialized_billable_xact_summary as mmbxs on (mmbxs.usr = au.id)
# where au.home_ou between START_HOME_OU and END_HOME_OU
# and ausp.standing_penalty = 1
# group by au.id
# having sum(mmbxs.balance_owed) < 25;
# 

# Example usage:
# ./recalc_penalties_direct.pl
#

#use strict; use warnings;

use LWP;
use Getopt::Std;
use JSON::XS;
use Text::CSV;
use Data::Dumper;
use OpenILS::Utils::Cronscript;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Const qw(:const);
use OpenSRF::AppSession;
use OpenSRF::EX qw(:try);
use Encode;
use Scalar::Util qw(blessed);
use Loghandler;
use DBhandler;
use Mobiusutil;
use XML::Simple;

my $logfile = @ARGV[0];
my $xmlconf = "/openils/conf/opensrf.xml";
 

if(@ARGV[1])
{
	$xmlconf = @ARGV[1];
}

if(! -e $xmlconf)
{
	print "I could not find the xml config file: $xmlconf\nYou can specify the path when executing this script\n";
	exit 0;
}
 if(!$logfile)
 {
	print "Please specify a log file\n";
	print "usage: ./recalc_penalties_direct.pl /tmp/logfile.log [optional /path/to/xml/config/opensrf.xml]\n";
	exit;
 }

my $log = new Loghandler($logfile);
$log->deleteFile();
$log->addLogLine(" ---------------- Script Starting ---------------- ");

my %conf = %{getDBconnects($xmlconf,$log)};
my @reqs = ("dbhost","db","dbuser","dbpass","port"); 
my $valid = 1;
for my $i (0..$#reqs)
{
	if(!$conf{@reqs[$i]})
	{
		$log->addLogLine("Required configuration missing from conf file");
		$log->addLogLine(@reqs[$i]." required");
		$valid = 0;
	}
}
if($valid)
{	
	my $dbHandler;
	
	eval{$dbHandler = new DBhandler($conf{"db"},$conf{"dbhost"},$conf{"dbuser"},$conf{"dbpass"},$conf{"port"});};
	if ($@) 
	{
		$log->addLogLine("Could not establish a connection to the database");
		print "Could not establish a connection to the database";
	}
	else
	{
		my $mobutil = new Mobiusutil();
		my @usrcreds = @{createDBUser($dbHandler,$mobutil,"1")};
		
		
		if(@usrcreds[3])
		{
			print "Ok - I am connected to:\n".$conf{"dbhost"}."\n".$conf{"db"}."\n".$conf{"dbuser"}."\n".$conf{"dbpass"}."\n".$conf{"port"}."\n";
			OpenSRF::System->bootstrap_client(config_file => '/openils/conf/opensrf_core.xml'); 
			my $script = OpenILS::Utils::Cronscript->new;
			my $authtoken = $script->authenticate(
				{
					username => @usrcreds[0],
					password => @usrcreds[1],
					workstation => @usrcreds[2]
				}
			);
			
			
			my $query = "select usr from action.circulation where due_date> (now()-('48 hours'::interval)) and xact_finish is null and checkin_time is null and usr in(select usr from actor.usr_standing_penalty where standing_penalty not in(1,2,3,4))";
			my @tem = (33655); #test user that I updated to have a lot of overdues
			my @results =([@tem]);# @{$dbHandler->query($query)};
			$log->addLogLine("Got: ". $#results." users to check");
			print "Got: ". $#results." users to check\n";
			my $session = OpenSRF::AppSession->create('open-ils.actor');
			foreach(@results)
			{
				print "row\n";
				my $row = $_;
				my @row = @{$row};
				foreach(@row)
				{
					my $userID = $_;
					try 
					{
						my $r = $session->request('open-ils.actor.user.penalties.update', $authtoken,  $userID );
						print Dumper $r;
            
					} 
					catch Error with 
					{
						my $err = shift;
						print "Error: $err\n";
					}
				}
			}
			$session->finish();
			#deleteDBUser($dbHandler,\@usrcreds);
		}
		else
		{
			$log->addLogLine("Failed creating the user/workstation in the DB\nusr:".@usrcreds[0]." pass: ".@usrcreds[1]." workstation: ".@usrcreds[2]);
			print "Failed creating the user/workstation in the DB\nusr:".@usrcreds[0]." pass: ".@usrcreds[1]." workstation: ".@usrcreds[2];
		}
		
	}
}
# while (my $line = <$IDFILE>) {
    # chomp($line);
    # print "Updating penalties for user " . $line . " ... ";

    # my $url = $gateway . '?service=open-ils.actor&method=open-ils.actor.user.penalties.update&param="' . $auth . '"&param=' . $line;

    # my $response = $browser->get($url);

    # die "Error!\n ", $response->status_line,
        # "\n Aborting" unless $response->is_success;

    # my $content = $response->content;

    # my $decoded = decode_json($content);

    # print "OK" if ($decoded->{status} == "200");

    # sleep($sleep_duration);

    # print "\n";
# }

$log->addLogLine(" ---------------- Script Ending ---------------- ");

sub getDBconnects
{
	my $openilsfile = @_[0];
	my $log = @_[1];
	my $xml = new XML::Simple;
	my $data = $xml->XMLin($openilsfile);
	my %conf;
	$conf{"dbhost"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{host};
	$conf{"db"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{db};
	$conf{"dbuser"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{user};
	$conf{"dbpass"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{pw};
	$conf{"port"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{port};
	#print Dumper(\%conf);
	return \%conf;

}

sub createDBUser
{
	my $dbHandler = @_[0];
	my $mobiusUtil = @_[1];
	my $org_unit_id = @_[2];
	my $usr = "recalc-penalty";
	my $workstation = "recalc-penalty-script";
	my $pass = $mobiusUtil->generateRandomString(10);
	
	my %params = map { $_ => 1 } @results;
	
	my $query = "select usrname from actor.usr where upper(usrname) = upper('$usr')";
	my @results = @{$dbHandler->query($query)};
	my $result = 1;
	if($#results==-1)
	{
		$query = "INSERT INTO actor.usr (profile, usrname, passwd, ident_type, first_given_name, family_name, home_ou) VALUES ('25', E'$usr', E'$pass', '3', 'Script', 'Script User', E'$org_unit_id')";
		$result = $dbHandler->update($query);
	}
	if($result)
	{
		$query = "select name from actor.workstation where upper(name) = upper('$workstation') and owning_lib=$org_unit_id ";
		my @results = @{$dbHandler->query($query)};
		if($#results==-1)
		{
			$query = "INSERT INTO actor.workstation (name, owning_lib) VALUES (E'$workstation', E'$org_unit_id')";		
			$result = $dbHandler->update($query);
		}
	}
	print "User: $usr\npass: $pass\nWorkstation: $workstation";
	
	@ret = ($usr, $pass, $workstation, $result);
	return \@ret;
}

sub deleteDBUser
{
	my $dbHandler = @_[0];
	my @usrcreds = @{@_[1]};
	my $query = "delete from actor.usr where usrname='".@usrcreds[0]."'";
	print $query."\n";
	$dbHandler->update($query);	
	$query = "delete from actor.workstation where name='".@usrcreds[2]."'";
	print $query."\n";
	$dbHandler->update($query);
}

