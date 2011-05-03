#!/usr/bin/env perl 
#===============================================================================
#
#         FILE:  ai-test.pl
#
#        USAGE:  ./ai-test.pl 
#
#  DESCRIPTION:  
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Alex Radetsky (Rad), <rad@rad.kiev.ua>
#      COMPANY:  Net.Style
#      VERSION:  1.0
#      CREATED:  04/25/11 16:08:01 EEST
#     REVISION:  ---
#===============================================================================

use 5.8.0;
use strict;
use warnings;

use lib '..'; 
use lib '/Users/rad/git/perl-NetSDS/NetSDS/lib';

use NetSDS::AutoInformator; 

my $ai = NetSDS::AutoInformator->new ( 
	target_name => "pobeda",
	target => { 
    context => 'Windication-Incoming',
    maxcalls => 'auto',
    queue => 'windication1',
    dsn => 'dbi:Pg:dbname=mydb;host=192.168.1.53;port=5432',
    login => 'asterisk',
    passwd => 'supersecret',
    table => 'predictive_dialing',
    where => ''
  },
conf => {
  allowed_time => '9:00-23:00',
	asterisk => { 
		astManagerHost=>'192.168.1.98',
    astManagerPort=>'5038',
    astManagerUser => 'autoinformator',
    astManagerSecret => 'supersecret'
	}, 
  routing => { 
		default => { 
			callerid=>'3039338', 
			trunk=>'SIP/telco',
		},
	},
	trunk => { 
		'SIP/telco' => 1, 
	}, 
}

); 

$ai->start();
$ai->run(); 


1;
#===============================================================================

__END__

=head1 NAME

ai-test.pl

=head1 SYNOPSIS

ai-test.pl

=head1 DESCRIPTION

FIXME

=head1 EXAMPLES

FIXME

=head1 BUGS

Unknown.

=head1 TODO

Empty.

=head1 AUTHOR

Alex Radetsky <rad@rad.kiev.ua>

=cut

