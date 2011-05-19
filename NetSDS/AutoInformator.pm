#===============================================================================
#
#         FILE:  AutoInformator.pm
#
#  DESCRIPTION:  Core class for NetSDS-VoiceInformer. 
# 							 
#
#        NOTES:  ---
#       AUTHOR:  Alex Radetsky (Rad), <rad@rad.kiev.ua>
#      COMPANY:  Net.Style
#      VERSION:  1.0
#      CREATED:  04/25/11 15:09:44 EEST
#LAST MODIFIED:  05/03/11 23:10:00 EEST 
#===============================================================================
=head1 NAME

NetSDS::

=head1 SYNOPSIS

	use NetSDS::;

=head1 DESCRIPTION

C<NetSDS> module contains superclass all other classes should be inherited from.

=cut

package NetSDS::AutoInformator;

use 5.8.0;
use strict;
use warnings;

use Data::Dumper; 
use NetSDS::Asterisk::Originator;
use NetSDS::Asterisk::EventListener; 
use NetSDS::DBI; 
use NetSDS::Logger; 
use NetSDS::Util::String; 
use Date::Manip; 
use Carp; 
use base qw(NetSDS::Class::Abstract);

use version; our $VERSION = "0.01";
our @EXPORT_OK = qw();

__PACKAGE__->mk_accessors('logger');

#===============================================================================
#
=head1 CLASS METHODS

=over

=item B<new([...])> - class constructor

    my $object = NetSDS::SomeClass->new(%options);

=cut

#-----------------------------------------------------------------------
sub new {

	my ( $class, %params ) = @_;
	
  my $this = $class->SUPER::new(%params);
  $this->{'active_destinations'} = {}; 

	return $this;

};

#***********************************************************************
=head1 OBJECT METHODS

=over

=item B<user(...)> - object method

=cut

#-----------------------------------------------------------------------
__PACKAGE__->mk_accessors('dbh');
__PACKAGE__->mk_accessors('el'); # Event Listener 
__PACKAGE__->mk_accessors('orig'); # Originator; 


=item B<start> 

Connects to the syslog, asterisk and database. 
returns undef if some operation failed. 

=cut 

sub start {

	my ( $this, %attrs ) = @_;

  $SIG{INT} = sub {
        die "SIGINT";
  };

  $SIG{TERM} = sub {
				die "SIGTERM"; 
  };



  # Create syslog handler
  if ( !$this->logger ) {
    $this->logger( NetSDS::Logger->new ( name =>'NetSDS-AutoInformator#'. $this->{target_name} ) );
    $this->log( "info", "Logger started" );
  }

  # Try to connect to the DSN: 
  my $dsn    = $this->{target}->{'dsn'}; 
  my $login  = $this->{target}->{'login'}; 
  my $passwd = $this->{target}->{'passwd'}; 
  
  $this->dbh ( NetSDS::DBI->new ( 
		dsn    => $dsn, 
    login  => $login, 
    passwd => $passwd,
		attrs  =>  { RaiseError => 1, AutoCommit => 1 },
  ) ); 

  unless ( defined ( $this->dbh->{dbh} ) ) { 
	  $this->log("error",$this->dbh->{_errstr}); 
		die; 
  }

  # Checks for table exists
  my $table = $this->{target}->{'table'}; 
  my $sth = $this->dbh->call("select count(*) from ".$table);
  my $row = $sth->fetchrow_hashref();
  unless ( defined ($row ) ) { 
		# table does not exist; 
	  $this->log("error", "Table $table does not exist.");
	  die;  
  }
 
  # Asterisk connect   
  # Set Asterisk Parameters
  my $astManagerHost   = $this->{conf}->{'asterisk'}->{'astManagerHost'};
  my $astManagerPort   = $this->{conf}->{'asterisk'}->{'astManagerPort'};
  my $astManagerUser   = $this->{conf}->{'asterisk'}->{'astManagerUser'};
  my $astManagerSecret = $this->{conf}->{'asterisk'}->{'astManagerSecret'};  

  # Set Event Listener
  my $event_listener = NetSDS::Asterisk::EventListener->new(
        host     => $astManagerHost,
        port     => $astManagerPort,
        username => $astManagerUser,
        secret   => $astManagerSecret
  );

  my $el_connected = $event_listener->_connect(); 
  unless ( defined ( $el_connected ) ) { 
		$this->log("error","Can't connect to asterisk via $astManagerHost:$astManagerPort");
		$this->log("error", $event_listener->{'error'});  
	  die "Can't connect to asterisk: ". $event_listener->{'error'};
  }

  $this->el( $event_listener ) ; 

	return 1; 

};

=item B<run> 

  Reading the database, run async many calls.  

=cut 

sub run { 
  my $this = shift; 
  while (1) {
		$this->log("info", "Begin cycle"); 
    my $is_allowed_time = $this->_is_allowed_time();  
	  unless ( defined ( $is_allowed_time) ) { 
			sleep(5);
			next; 
		}

    # Now it's allowed. Let's find parameters of target and get next N records; 
    my $next_records_count = $this->_get_next_records_count(); 
	  unless ( defined ($next_records_count) ) { 
			die; 
		}

		$this->log("info","Next records count = " . $next_records_count); 

		unless ( $next_records_count ) { 
			goto EventListen; 
		} 
		

		# We have next_records_count of next_records to make parallel calls. 
	  # От максимального количества отнимаем то, что прямой сейчас звонит. 
	
	  if ( defined ($this->{'dialed'} ) ) { 
			my $current_active_calls = keys @{ $this->{'dialed'} }; 
			$next_records_count = $next_records_count - $current_active_calls; 
			$this->log('info',"next_record_count ($next_records_count) - $current_active_calls"); 
		}

		# Prepared record is the arrayref of records as hashref
   	my $prepared_records = $this->_get_next_records ($next_records_count); 
		unless ( defined ($prepared_records) ) { 
			die; 
		}
		my $data_count = @{$prepared_records}; 
		if ($data_count == 0) { 
			$this->log("info","No data."); 
			goto EventListen; 
		} 
	  foreach my $record ( @{$prepared_records} ) { 
			$this->log("info","Make call to ".$record->{'id'}.":".$record->{'destination'}."\n"); 

      my $dialed = $this->_fire($record);
			if ( $dialed ) {
			  # Заносим в анналы, что туда в destination мы звоним прямо сейчас.
				$this->{'dialed'}->{str_trim($record->{'destination'})} = $record->{'id'};
			} 
    }

EventListen: 

    # Reading Event Listener ; 
	  while ( my $event = $this->el->_getEvent() ) { 
			unless ( defined ($event->{'Event'} ) ) { 
				next; 
			} 
			if ($event->{'Event'} =~ /OriginateResponse/i ) { 
				my $dst = $event->{'ActionID'}; 
				if ($event->{'Response'} =~ /Failure/i ) { 
					my $ch = $event->{'Channel'}; 
				  $ch =~ s/\/$dst//g; 
					$this->_dec_bt($ch);
					$this->log("info","Dial to $dst failed.");
					$this->_dial_failure ( $dst ); 
				}
				if ($event->{'Response'} =~ /Success/i ) { 
					my ($trunkname,$trunk_id) = split('-',$event->{'Channel'}); 
				  $this->_dec_bt($trunkname); 
				  $this->log("info","Dial to $dst success."); 
					$this->_dial_success ( $dst ); 
				} 

			} 
		}
		sleep(1); 
	  $this->log("info", "End of cycle"); 
  }
	return 1; 
}

=item B<_dial_success> 

	Update table to success state. Remove from memory by ID. 

=cut 

sub _dial_success { 
	my $this = shift; 
	my $destination = shift; 

  my $id = $this->{'dialed'}->{$destination}; 

  my $table = $this->{'target'}->{'table'}; 
	my $strQuery = "update $table set done_date=now() where id=$id"; 
	$this->dbh->call($strQuery); 

  delete $this->{'dialed'}->{$destination}; 
	
	return 1; 
} 


sub _dial_failure { 
	my $this = shift; 
	my $destination = shift;  

	delete $this->{'dialed'}->{$destination}; 

  return 1; 
}

=item B<_fire> 

 Make a call to destination 

=cut 

sub _fire {
	my $this = shift; 
	my $record = shift; 
	
	my $destination = str_trim( $record->{'destination'} );
	my $userfield = str_trim( $record->{'userfield'} );
  
	my $id  = $record->{'id'};
	my $context = $this->{'target'}->{'context'}; 
	unless ( defined ( $context ) ) { 
		$context = 'default'; 
	} 
  
	my $channel_variables = $this->_join_variables_from_userfield ($userfield,$id); 
 	
	my $channel = $this->_find_channel($record->{'destination'}); 
  unless ( defined ( $channel ) ) { 
		$this->log("info","No free channel available for $destination. Skip it."); 
		return undef; 
	}
  
	my $callerid = $channel->{'callerid'}; 
	my $trunkname = $channel->{'trunkname'}; 

  # Update table for current try; 
	$this->_increment_tries($record); 

  # Originate to: 
	# destination 
	# context 
	# channel
  my $orig = NetSDS::Asterisk::Originator->new(
            actionid       => $destination,
            destination    => $destination,
            callerid       => $callerid,
            return_context => $context,
            variables      => $channel_variables,
            channel        => $trunkname.'/'.$destination);
  
  # Set Asterisk Parameters
  my $astManagerHost   = $this->{conf}->{'asterisk'}->{'astManagerHost'};
  my $astManagerPort   = $this->{conf}->{'asterisk'}->{'astManagerPort'};
  my $astManagerUser   = $this->{conf}->{'asterisk'}->{'astManagerUser'};
  my $astManagerSecret = $this->{conf}->{'asterisk'}->{'astManagerSecret'}; 

  my $reply = $orig->originate(
            $astManagerHost, $astManagerPort,
            $astManagerUser, $astManagerSecret
  );

  unless ( defined($reply) ) {
    $this->log( "warning", "Originate to $destination failed." );
		$this->_dec_bt($trunkname); 
    return undef; 
  }

  return 1; 
}
=item B<_join_variables_from_userfield>

changes & to | and add ID as channel variable 

=cut 

sub _join_variables_from_userfield { 
	my $this = shift; 
	my $userfield = shift; 
  my $id = shift; 

	$userfield =~ s/&/|/g; 
  $userfield .= '|ID='.$id; 

  return $userfield; 
}
=item B<_dec_busy_trunks> 

  dec busy_trunks->trunk_name,1; 

=cut 

sub _dec_bt { 
	my $this = shift; 
	my $trunkname = shift; 

	my $busy_trunks = $this->{'busy_trunks'}->{$trunkname}; 
  $busy_trunks = $busy_trunks - 1; 
	$this->{'busy_trunks'}->{$trunkname} = $busy_trunks; 
	$this->log( "info", "Decrease $trunkname busy_trunks to $busy_trunks"); 
  return 1; 
} 

=item B<_find_channel> 

We have tables routing, trunkgroups, trunks. 
routing := prefix { callerid + trunk | trunkgroup }  

-- Russian mode on --
Конфигурационный раздел routing содержит таблицу маршрутизации по префиксам,
префикс 
  callerid 
	trunk или trunkgroup 

callerid = подставляемый callerid 
trunkgroup = ссылка на имя транкгруппы 
trunk = имя конкрентного транка 

транкгруппа содержит список транков и количество каналов, соответствующее каждому транку, которое можно занять. 
trunks содержит просто список транков и количество каналов, которое можно занять в этом транке 

trunkgroup - это список транков и каналов к ним, которые перебираются по кругу при попытке найти свободный транк. 
trunk - это просто транк, который мы выбираем для осуществления звонка с проверкой по занятости. 

-- Russian mode off -- 

=cut 

sub _find_channel { 
	my ($this,$destination) = @_; 

  my $routing = $this->{'conf'}->{'routing'};
	my $prefix = undef; 

	foreach my $mask ( keys %{ $routing } ) { 
		if ($destination =~ /^$mask/ ) { 
			$prefix = $mask; 
			last;
		}
	}
	unless ( defined ($prefix) ) { 
		$prefix = 'default'; 
	} 

	my $callerid = $routing->{$prefix}->{'callerid'}; 
	unless ( defined ($callerid ) ) { 
		$callerid = ""; 
	} 
	$this->log('info', "Selected route: ".$prefix. " with callerid=\'$callerid\'");  
  my $trunkname = $this->_find_correspondent_trunk ($routing->{$prefix}); 
  unless ( defined ($trunkname) ) { 
		return undef; 
	} 
  return { callerid => $callerid, trunkname => $trunkname }; 
}

sub _find_correspondent_trunk { 
	my ($this,$prefix) = @_; 

  if ( defined ( $prefix->{'trunk'} ) ) { 
		my $trunkname = $prefix->{'trunk'}; 
		my $trunkmaxchannels = $this->{'conf'}->{'trunk'}->{$trunkname}; 
		unless ( defined ( $trunkmaxchannels ) ) { 
			$this->log('warning',"Can't find maxchannels for trunk $trunkname. Using maxchannels=1."); 
			$trunkmaxchannels = 1; 
		} 
    my $busy_trunks = 0; 
		unless ( defined ( $this->{'busy_trunks'}->{$trunkname} ) ) { 
			$busy_trunks = 0; 
		} else { 
			$busy_trunks = $this->{'busy_trunks'}->{$trunkname};
		} 
		if ($busy_trunks >= $trunkmaxchannels ) { 
			$this->log("info","Trunk $trunkname filled for maximum."); 
			return undef; 
		} 
		$busy_trunks = $busy_trunks + 1; 
    $this->{'busy_trunks'}->{$trunkname} = $busy_trunks;
	 	$this->log("info","Selecting $trunkname. Incrementing busy_trunks to $busy_trunks."); 
	  return $trunkname; 	
 	}
 
	if ( defined ( $prefix->{'trunkgroup'} ) ) {
	  my $trunkgroupname = $prefix->{'trunkgroup'}; 
  	if ( defined ( $this->{'conf'}->{'trunkgroup'}->{$trunkgroupname} ) ) { 
			foreach my $trunkname ( keys %{$this->{'conf'}->{'trunkgroup'}->{$trunkgroupname}} ) {  	
		    my $trunkmaxchannels = $this->{'conf'}->{'trunkgroup'}->{$trunkgroupname}->{$trunkname}; 
				unless ( defined ( $trunkmaxchannels ) or $trunkmaxchannels ) { 
					$trunkmaxchannels = 1; 
					$this->log('warning',"Can't find maxchannels for trunk $trunkname in trunkgroup $trunkgroupname. Using maxchannels=1.");
				}
		    my $busy_trunks = 0; 
				unless ( defined ( $this->{'busy_trunks'}->{$trunkname} ) ) { 
					$busy_trunks = 0; 
				} else { 
					$busy_trunks = $this->{'busy_trunks'}->{$trunkname};
				} 
				if ($busy_trunks >= $trunkmaxchannels ) { 
					next; 
				} else {
					$this->log("info","Selecting $trunkname in trunkgroup $trunkgroupname. Incrementing busy_trunks to $busy_trunks."); 
					$busy_trunks = $busy_trunks + 1; 
    			$this->{'busy_trunks'}->{$trunkname} = $busy_trunks;
					return $trunkname;  
				}
			}
		} 
  }

  return undef 
}

sub _increment_tries { 
	my $this = shift; 
	my $record = shift; 

	my $id = $record->{'id'}; 
	my $table = $this->{'target'}->{'table'}; 
  
	$this->log("info","Increment tries for ".$record->{'id'}.":".$record->{'destination'}); 
	my $strQuery = "update $table set when_last_try=now(), tries=tries+1 where id=$id";  
	#$this->dbh->begin(); 
	$this->dbh->call($strQuery); 
	#$this->dbh->commit(); 
	return 1; 
}


=item B<_get_next_records> 

=cut

sub _get_next_records {
	my $this = shift; 
	my $limit = shift; 

  my $maxtries = $this->{'conf'}->{'max_tries_for_one_destination'}; 
  unless ( defined ( $maxtries ) ) { 
		$this->log("warning","Undefined max_tries_for_one_destination in config. Using 10."); 
		$maxtries = 10; 
	} 
	my $strLimit = "limit $limit"; 
	my $strWhere = $this->{'target'}->{'where'}; 
 
  my $strTable = $this->{'target'}->{'table'}; 

  my $strSelect = "select id, destination, userfield"; 
	my $strQuery  = $strSelect . " from " . $strTable . " where done_date is null and (since < now() and till > now() ) and tries < $maxtries "; 
 
  if ( defined ( $strWhere ) and $strWhere ne '') { 
		$strQuery .= "and " . $strWhere;
	} 
  $strQuery .= "order by tries desc "; 
  $strQuery .= $strLimit; 

  my $data = $this->dbh->fetch_call($strQuery); 

  my $data_count = @{$data};  
	$this->log("info","Got $data_count records"); 

  return $data; 
	# returning array of array of hashrefs. 
	# if it's empty returning [] (empty array); 

}

=item B<_get_next_records_count> 

 Analyze the target parameters and find the correspondent count for next records
 Анализирует параметры цели и пытается вычислить максимальное количество звонков параллельных.

=cut 

sub _get_next_records_count { 

  my $this = shift; 
  unless ( defined ( $this->{target}->{'maxcalls'} ) ) { 
		$this->log ("warning","maxcalls undefined. Epic Fail."); 
		return undef; 
	}
  
	# Если maxcalls =~ auto, то вычисляем auto. 

	if ($this->{target}->{'maxcalls'} =~ /auto/i ) { 
		if ( defined ( $this->{target}->{'queue'} ) ) { 
			my $maxcalls = $this->_get_queue_free_operators ($this->{target}->{'queue'});
		  unless ( defined ($maxcalls) ) {
				$this->log("error","Can't get free operators. Epic Fail."); 
				return undef; 
			} 
			unless ( $maxcalls ) { 
				$this->log("warning","Queue does not contain free operators. Strange."); 
			}
			if ( defined ( $this->{target}->{'predictive_calls'} ) ) { 
				$maxcalls += $this->{target}->{'predictive_calls'}; 
			}
			return $maxcalls; 
		}
		$this->log("warning","Maxcalls=auto but queue undefined."); 
		return undef; 
	}

  my $maxcalls = $this->{target}->{'maxcalls'}; 
	unless ( $maxcalls ) { 
		$this->log ("warning", "maxcalls must be > 0"); 
		return undef; 
	} 
  return $maxcalls; 
}

=item B<_get_queue_free_operators> 

 Пытается получить кол-во свободных операторов в очереди.

=cut 
sub _get_queue_free_operators { 

	my $this = shift; 
	my $queuename = shift; 

  # Set Asterisk Parameters
  my $astManagerHost   = $this->{conf}->{'asterisk'}->{'astManagerHost'};
  my $astManagerPort   = $this->{conf}->{'asterisk'}->{'astManagerPort'};
  my $astManagerUser   = $this->{conf}->{'asterisk'}->{'astManagerUser'};
  my $astManagerSecret = $this->{conf}->{'asterisk'}->{'astManagerSecret'}; 

  my $astManager = NetSDS::Asterisk::Manager->new ( 
		host 			=> $astManagerHost,
		port			=> $astManagerPort,
		username 	=> $astManagerUser,
		secret	  => $astManagerSecret,
		events	  => 'Off',
	);

	my $connected = $astManager->connect();
	unless ( defined ( $connected ) ) { 
		$this->log("warning","Can't connect to the asterisk: ".$astManager->geterror() ); 
		return undef; 
	} 

  my $sent = $astManager->sendcommand( 'Action' => 'QueueStatus' );
	unless ( defined($sent) ) {
		$this->log("warning","Can't send the command QueueStatus: " .$astManager->geterror()  );
		return undef;
	}

	my $reply = $astManager->receive_answer();
  unless ( defined($reply) ) {
	  $this->log("warning","Can't receive the answer:" .$astManager->geterror() ); 
		return undef;
	}

	my $status = $reply->{'Response'};
	unless ( defined($status) ) {
		$this->log("warning","Answer does not contain 'Response' field.");
		return undef;
	}

  if ( $status ne 'Success' ) {
		$this->log("warning","Response not success: ".$status );
		return undef;
	}

  # reading from socket while did not receive Event: StatusComplete

	my @replies;
	while (1) {
		my $reply  = $astManager->receive_answer();
		$status = $reply->{'Event'};
		if ( $status eq 'QueueStatusComplete' ) {
			last;
		}
		push @replies, $reply;
	}

  # warn Dumper (\@replies);

  my $free_operators = 0; 
  foreach my $reply (@replies) { 
		if ($reply->{'Event'} =~ /QueueMember/) {
			if ($reply->{'Queue'} eq $queuename) { 
				if ($reply->{'Status'} == 1) { 
					$free_operators = $free_operators + 1; 
				}
			}
		}
  }

	return $free_operators; 
	
} 


=item B<_is_allowed_time>

  Check for allowed_time. When allowed time undefined allow to call any time. 

=cut 

sub _is_allowed_time { 
  my $this = shift;

	unless ( defined (  $this->{conf}->{allowed_time} ) ) {
	  $this->log ("info", "Config does not contain allowed_time. Allow it 24h. "); 
		return 1; 
  }

  my ($begin,$end) = split('-',$this->{conf}->{allowed_time}); 
  my $now    = ParseDate('now'); 
  my $today  = ParseDate('today'); 
  my $tbegin = ParseDate( $begin  ); 
  my $tend   = ParseDate ( $end  ); 

  my $flag1 = Date_Cmp($now,$tbegin); 
	my $flag2 = Date_Cmp($now,$tend);
  
	if ($flag1 > 0 and $flag2 < 0 ) {
	  $this->log("info","Allowed time between ".Dumper ($tbegin) . " and " . Dumper ($tend) ); 
		return 1; 
	}
	$this->log("info"," Not Allow to call !"); 
	return undef; 

}
=item B<stop>

  Stops connections to database, asterisk, syslog. 

=cut 
sub stop { 

	my $this = shift; 

  return 1; 

} 

sub log {

  my ( $this, $level, $message ) = @_;
  # Try to use syslog handler
  if ( $this->logger() ) {
    $this->logger->log( $level, $message );
  } else {
    carp "[$level] $message";
  }
  return undef;
}    ## sub log


1;

__END__

=back

=head1 EXAMPLES


=head1 BUGS

Unknown yet

=head1 SEE ALSO

None

=head1 TODO

None

=head1 AUTHOR

Alex Radetsky <rad@rad.kiev.ua>

=cut


