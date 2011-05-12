#!/usr/bin/env perl 
#===============================================================================
#
#         FILE:  NetSDS-VoiceInformer.pl
#
#        USAGE:  ./NetSDS-VoiceInformer.pl 
#
#  DESCRIPTION:  This is the third version of project that must use Asterisk to make 
#                many parallel calls with returning to IVR/Queue. 
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Alex Radetsky (Rad), <rad@rad.kiev.ua>
#      COMPANY:  Net.Style
#      VERSION:  1.0
#      CREATED:  04/04/11 22:12:19 EEST
#     REVISION:  ---
#===============================================================================

use 5.8.0;
use strict;
use warnings;

NetSDSVoiceInformer->run(
    daemon      => undef,
    verbose     => 1,
    use_pidfile => 1,
    has_conf    => 1,
    debug       => 1,
    conf_file   => "./voiceinformer.conf",
    infinite    => undef,

);

1;

package NetSDSVoiceInformer;

use lib '/Users/rad/git/perl-NetSDS/NetSDS/lib'; 
use lib '/Users/rad/git/perl-NetSDS-Util/NetSDS-Util/lib/'; 

use base 'NetSDS::App'; 

use Data::Dumper;
use NetSDS::AutoInformator; 

use POSIX ":sys_wait_h";

# Start 
# У нас есть N целей. Для каждой из них надо создать свой процесс. 
# Master-Process остается в режиме ожидания. 

my @CHILDREN; 

sub start { 
	my $this = shift;
  # Для каждой цели запускаем свой процесс. 
	foreach my $target_name ( keys %{ $this->{conf}->{'targets'} } ) {  
		 my $target = $this->{conf}->{'targets'}->{$target_name};
		 # Check the target for all correct parameters
		 my $is_target_correct = $this->is_target_correct($target, $target_name); 
		 unless ( defined ($is_target_correct ) ) { 
		 	$this->speak("[$$] The target called '".$target_name."' with these parameters is incorrect. Please RTFM! Ignoring it. "); 
			$this->speak("[$$] Parameters dump: " . Dumper ($target) ); 
			next;
		 }
		 my $child = $this->burn_child ($target, $target_name, $this->{conf});
		 push @CHILDREN, $child; 
  }
	$this->_add_signal_handlers(); 

} 
sub _add_signal_handlers {
    my $this = @_;

    $SIG{INT} = sub {
        my $perm = kill "TERM" => @CHILDREN;
        die "SIGINT";
    };

    $SIG{TERM} = sub {
        my $perm = kill "TERM" => @CHILDREN;
				die "SIGTERM"; 
    };

	  $SIG{CHLD} = sub {
			while ( ( my $child = waitpid(-1,WNOHANG )) > 0) { 
				grep { $_ != $child } @CHILDREN; # CleanUp the array
				my $perm = kill "TERM" => @CHILDREN;
				die "$child was died : $!\n"; 
			}
		};

}

sub burn_child { 
	my ($this, $target, $target_name, $conf) = @_; 
  
  my $pid = fork();
	unless ( defined($pid) ) {
  	die "Fork failed: $! \n"; 
  }

  if ($pid == 0) { 
		# This is a child. 
		my $ai = NetSDS::AutoInformator->new (
			target => $target, 
			target_name => $target_name, 
			conf => $conf
		);

		my $ai_started = $ai->start();
		unless ( defined ( $ai_started ) ) { 
			exit; 
		} 
		$ai->run(); 
		$ai->stop();
		exit; 
	} 
  
	return $pid; 

}

=item B<is_target_correct> 

 This method checks given target for all required parameters. Like dsn, context, table. 

=cut 
sub is_target_correct { 
	my ($this, $target, $target_name) = @_; 

  unless ( defined ( $target->{'context'} ) ) { 
		$this->speak ("[$$] The target '".$target_name."' does not have any context."); 
    return undef; 
	}

	unless ( defined ( $target->{'dsn'} ) ) { 
		$this->speak ("[$$] The target '".$target_name."' does not have DSN "); 
		return undef; 
	} 

	unless ( defined ( $target->{'login'} ) ) { 	
		$this->speak ("[$$] The target '".$target_name."' does not have login "); 
		return undef 
	}

	unless ( defined ( $target->{'passwd'} ) ) { 	
		$this->speak ("[$$] The target '".$target_name."' does not have passwd "); 
		return undef 
	}

	unless ( defined ( $target->{'table'} ) ) { 
		$this->speak ("[$$] The target '".$target_name."' does not have TABLE name. "); 
	  return undef; 
	} 

	return 1; 
}

sub process { 
	my $this = shift; 

	while (1) { 
	 	sleep (1); 
	} 

}

1;
#===============================================================================

__END__

=head1 NAME

NetSDS-VoiceInformer.pl

=head1 SYNOPSIS

NetSDS-VoiceInformer.pl

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

