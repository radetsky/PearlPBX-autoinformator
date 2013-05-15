#!/usr/bin/env perl 
#===============================================================================
#
#         FILE: Katyusha.pl
#
#        USAGE:  Katyusha.pl --daemon  
#
#  DESCRIPTION:  This is the fourth version of project that must use Asterisk to make 
#                many parallel calls with returning to IVR/Queue. 
#
#      OPTIONS:  ---
# REQUIREMENTS:  ---
#         BUGS:  ---
#        NOTES:  ---
#       AUTHOR:  Alex Radetsky (Rad), <rad@rad.kiev.ua>
#      COMPANY:  PearlPBX
#      VERSION:  4.0
#      CREATED:  29/04/13 22:12:19 EEST
#     REVISION:  ---
#===============================================================================

use 5.8.0;
use strict;
use warnings;

Katyusha->run(
    daemon      => undef,
    verbose     => 1,
    use_pidfile => 1,
    has_conf    => 1,
    debug       => 1,
    conf_file   => "/etc/PearlPBX/voiceinformer.conf",
    infinite    => undef,

);

1;

package Katyusha;

use lib '/Users/rad/git/perl-NetSDS/NetSDS/lib'; 
use lib '/Users/rad/git/perl-NetSDS-Util/NetSDS-Util/lib/'; 
use lib '/opt/NetSDS/lib';

use base 'NetSDS::App'; 

use Data::Dumper;
use NetSDS::Asterisk::Originator;
use NetSDS::Asterisk::EventListener;
use NetSDS::DBI;
use NetSDS::Logger;
use NetSDS::Util::String;
use Date::Manip;

use POSIX ":sys_wait_h";

# Start 
# У нас есть N целей. Раньше для каждой мы создавали отдельный процесс. 
# Теперь цели становяться в очередь. 

=item B<start> 

This is start procedure. Calling after initialize while NetSDS::App starting. 
1) Reading and analyze config 
2) Connect to the databases 
3) Connect to the asterisk with event listener 
4) Collect 1st calls list and originate it. 

=cut 

sub start { 
	my $this = shift;

	# Create syslog handler
    if ( !$this->logger ) {
        $this->logger ( NetSDS::Logger->new( name => 'katyusha' ) );
        $this->log( "info", "Katyusha v.4.0 started!" );
    }
	$this->_add_signal_handlers(); 
	
    $this->{targets} = undef; 

	# Читаем и анализируем каждую цель. А так же заносим в анналы. 
	foreach my $target_name ( keys %{ $this->{conf}->{'targets'} } ) {  
		 my $target = $this->{conf}->{'targets'}->{$target_name};

         $this->log("info", "Reading target: $target_name" );
         if ( $this->{debug} ) { print "Reading target: $target_name.\n"; } 

		 
         # Check the target for all correct parameters
		 my $is_target_correct = $this->is_target_correct($target, $target_name); 
		 unless ( defined ($is_target_correct ) ) { 
		 	$this->log("info","The target called '".$target_name."' with these parameters is incorrect."); 
			$this->log("info","Parameters dump: " . Dumper ($target) ); 
			die "Fatal error!\n"; 
		 }
		 $this->_target_db_connect ( $target, $target_name ); 
	}
	$this->_connect_event_listener();
    # Берем максимум звонков для каждой очереди 
    # Это только для старта. 
	my @list = $this->_create_calls_list(); 
    # и запихиваем в asterisk. 
	unless ( $this->_originate(@list) ) { 
        $this->finalize(); 
    }
} 


sub process { 
    my $this = shift;
    my $event_counter = 0; 

    if ( $this->{debug} ) { print "Process() started. \n"; } 

    # В процессе ожидания/получения OriginateResponse надо запускать ответные звонки 
    # по кругу . 

    # Хотя: если в идентификатор звонка включить название цели, то изначально распределив 
    # пропорционально ( кол-ву операторов + предиктив ) , можно потом по факту получения отлупа/события 
    # просто брать следующий звонок из очереди для указанной цели!!! 

    while ( 1 ) { 
        my $event = $this->{el}->_getEvent();
        next unless ( $event ); 
        next unless ( defined( $event->{'Event'}) );
        $event_counter = $event_counter + 1; 
        # print "[$$] ". $event_counter ." ". $event->{'Event'}. "\n"; 
    
        if ( $event->{'Event'} =~ /OriginateResponse/ ) { # Тут мы следим за ответами 
            #if ( $this->{'debug'} ) { 
            #     warn Dumper ($event); 
            #}

            if ( $this->_is_my_call($event) ) {
                my $actionId = $event->{'ActionID'}; 
                if ( $this->{debug} ) { 
                    printf ("OriginateResponse: %s, %s, %s \n", $event->{'Response'}, $event->{'Exten'}, $event->{'Channel'} ); 
                } 
                $this->log("info",sprintf("OriginateResponse: %s, %s, %s \n", $event->{'Response'}, $event->{'Exten'}, $event->{'Channel'}));

                if ($event->{'Response'} !~ /Success/ ) { 
                    delete $this->{originated}->{$actionId}; 

                    my ($target_name,$dest,$cid) = split (',', $actionId ); 
                    $this->_originate_next_record($target_name); 
                    next; 
                }
                # my ($c1,$c2) = split (';',$event->{'Channel'});  # Запомнили до hangup
                $this->{originated}->{$actionId}->{'channel'} = $event->{'Channel'}; 
                $this->{originated}->{$actionId}->{'start'} = time; 
                
            }
        }
        if ( $event->{'Event'} =~ /^Masquerade$/ ) { 
            # Найти и переименовать канал вызова 
            $this->_masquerade ($event); 
        }
        if ( $event->{'Event'} =~ /^Hangup$/ ) { 
            if ( $event->{'Channel'} =~ /ZOMBIE/ ) { next; }
            my $originated = $this->_hangup($event); 
            if ($originated) { 
                if ( $this->{debug} ) { 
                    printf("Hangup: %s, %s \n", $event->{'Cause'}, $event->{'Channel'}); 
                } 
                $this->log("info",sprintf("Hangup: %s, %s", $event->{'Cause'}, $event->{'Channel'}));

                if ($event->{'Cause'} != 16 ) { 
                    $this->_failure ( $originated );    
                } else { 
                    $this->_success ( $originated );
                }
                my ($target_name,$dest,$cid) = split (',',$originated->{'actionId'} ); 
                $this->_originate_next_record($target_name); 
            } # end if  
            #else { 
            #    warn "------ Lost call: ".$event->{'Channel'}; 
            #}
        } # end if 
    } # end while 
} # end sub 

sub _originate_next_record { 
    my ($this,$target_name) = @_; 

    my @list = $this->_get_calls( $this->{conf}->{targets}->{$target_name}, 1, $target_name ); 
    $this->_originate(@list);
}

sub _failure { 
    my ( $this, $originated ) = @_; 

    my ($target,$dest,$cid) = split (',',$originated->{'actionId'} ); 

    print "Failed call. Target: $target, destination: $dest \n";

    my $actionId = $originated->{'actionId'}; 
    delete $this->{originated}->{$actionId}; 

    return 1; 
}

sub _success { 
    my ($this, $originated) = @_; 

    $originated->{'stop'} = time; 
    
    $this->_update_success($originated);

    my $actionId = $originated->{'actionId'}; 
    delete $this->{originated}->{$actionId}; 

    return 1; 
}

sub _update_success { 
    my ($this, $originated) = @_; 

    my ($target,$dest,$cid) = split (',',$originated->{'actionId'} ); 

    my $seconds = 0; 

    unless ( defined ( $originated->{'stop'} ) ) { 
        if ($this->{debug} ) { 
            warn "Undefined originated->stop for ".$originated->{'actionId'}; 
        }
        $this->log("info", "Undefined originated->stop for ".$originated->{'actionId'});
        $seconds = 0;
    }
    unless ( defined ( $originated->{'start'} ) ) { 
        if ($this->{debug} ) { 
            warn "Undefined originated->start for ".$originated->{'actionId'}; 
        }
        $this->log("info", "Undefined originated->start for ".$originated->{'actionId'});
        $seconds = 0; 
    }

    if ( defined ( $originated->{'stop'} ) and defined ( $originated->{'start'} ) ) {
        $seconds = $originated->{'stop'} - $originated->{'start'};
    }

    if ( $this->{debug} ) {
        print "Update success. Target: $target, destination: $dest, billsec: $seconds \n";
    }
    $this->log("info","Update success. Target: $target, destination: $dest, billsec: $seconds");

    my $table = $this->{conf}->{targets}->{$target}->{'table'}; 
    my $id = $originated->{'id'}; 

    my $sql = "update $table set done_date=now(), billsec=$seconds where id=$id"; 
    $this->{targets}->{$target}->{dbh}->call($sql); 

}

sub _originate { 
	my ($this, @list) = @_; 

    # Если не подключен менеджер, то давайте подключаться. 
    unless ( $this->{manager_connected} ) { 
         unless ( $this->_manager_connect() ) {  
            $this->log("error","Can't connect to manager."); 
            die "Can't connect to manager.\n"; 
        }
    }  
 
	while ( my $call = shift @list ) { 
		my $destination = $call->{'destination'};
		my $id          = $call->{'id'}; 
		my $userfield   = $call->{'userfield'}; 
        my $context     = $call->{'context'}; 
        my $ocontext    = $call->{'ocontext'}; 
        my $actionId    = join (',', ( $call->{'target_name'}, $call->{'destination'},$call->{'id'} ) ); 
        # print Dumper ($actionId); 
        my $variables = $this->_join_variables_from_userfield( $userfield, $id );
        my $channel = "Local/".$destination."@".$ocontext;

        my $originated = { 'id' => $id, 'actionId' => $actionId, 'channel' => $channel }; 

        # Update table for current try;
        $this->_increment_tries($call);

        my $sent = $this->{manager}->sendcommand (
            Action   => 'Originate',
            Async    => 'On',
            Channel  => $channel,
            Exten    => $destination,
            Timeout  => 30000,
            Context  => $context,
            Variable => $variables,
            ActionID => $actionId, 
        );

        unless ( defined( $sent ) ) {
            $this->log( "warning", "Can't send the command Originate: " . $this->{manager}->geterror() );
            if ($this->{debug} ) { warn "Can't send the command Originate: " . $this->{manager}->geterror(); }
            return undef;
        }

        my $reply = $this->{manager}->receive_answer();
        unless ( defined($reply) ) {
            $this->log( "warning","Can't receive the answer:" . $this->{manager}->geterror() );
            if ($this->{debug} ) { warn "Can't receive the answer:" . $this->{manager}->geterror(); }
            return undef;
        }

        unless ( $reply ) { # returned; No data from socket. 
            $this->log("error", "No data from Manager while try to originate call to $destination.");
            if ($this->{debug} ) { warn  "No data from Manager while try to originate call to $destination."; } 
            return undef; 
        }

        my $status = $reply->{'Response'};
        unless ( defined($status) ) {
            $this->log( "warning", "Answer does not contain 'Response' field." );
            if ( $this->{debug} ) { warn "Answer does not contain 'Response' field." . Dumper ($reply); } 
            return undef;
        }

        if ( $status ne 'Success' ) {
            $this->log( "warning", "Response not success: " . $status );
            if ( $this->{debug} ) { warn "Response not success: " . Dumper ($reply); }
            return undef;
        }

        # А тут должен быть удачный ответ. 
        # warn Dumper ($reply); 
        $this->log("info",sprintf( "%s: %s, %s", $reply->{'Response'}, $reply->{'Message'}, $reply->{'ActionID'}));
        if ( $this->{debug} ) { 
            printf("%s: %s, %s\n", $reply->{'Response'}, $reply->{'Message'}, $reply->{'ActionID'}); 
        }

        $this->{originated}->{$actionId} = $originated; 

    }  
    return 1;
}


=item B<_create_calls_list>

	Создаёт список звонков, который надо выполнить за текущую итерацию. 
	Для этого функция получает максимальное количество звонков для каждой очереди. 

=cut 

sub _create_calls_list { 
	my ($this) = @_; 
	my @calls_list; 

	$this->_get_queue_status();
    
	foreach my $target_name ( keys %{ $this->{conf}->{'targets'} } ) {  
		 my $target = $this->{conf}->{'targets'}->{$target_name};
		 my $count_of_calls = $this->_get_count_of_calls($target, $target_name);
         # Здесь мы остановились. 

		 my @list = $this->_get_calls($target, $count_of_calls, $target_name);
		 push @calls_list,@list; 
	}
	return @calls_list; 
}

sub _get_calls { 
	my ($this, $target, $limit, $target_name) = @_; 

    my $maxtries = $this->{'conf'}->{'max_tries_for_one_destination'};
    unless ( defined ( $maxtries) ) {
        $this->log( "warning","Undefined max_tries_for_one_destination in config. Using 10." );
        $maxtries = 10;
    }

    my $strLimit = "limit $limit";
    my $strWhere = $target->{'where'};
    my $strTable = $target->{'table'};

    my $strSelect = "select id, destination, userfield,'".$target->{'context'}."' as context,'".$target->{'outgoing_context'}."' as ocontext ";
    my $strQuery = $strSelect . " from ". $strTable . " where done_date is null and (since < now() and till > now() ) and tries < $maxtries and destination ~ E\'^\\\\d+\\\\s+' ";

    if ( defined ($strWhere) and $strWhere ne '' ) {
        $strQuery .= "and " . $strWhere;
    }

    $strQuery .= "order by tries,id ";
    $strQuery .= $strLimit;

    my $data = $this->{targets}->{$target_name}->{dbh}->fetch_call($strQuery);
    my @newdata; 
    foreach my $element ( @{$data} ) { 
        $element->{'userfield'} = str_trim ($element->{'userfield'});
        $element->{'target_name'} = $target_name; 
        $element->{'destination'} = str_trim ( $element->{'destination'}); 
        push @newdata,$element; 
    } 

    my $data_count = @{$data};
    if ( $this->{debug} ) { print " ======== $data_count records for [ $target_name ] ======== \n"; }
    $this->log( "info", " ======== $data_count records for [ $target_name ] ======== " );

    # print Dumper (\@newdata); 
    return @newdata; 
}

sub _get_count_of_calls { 
	my ($this, $target, $target_name) = @_; 
	my $count_of_calls = 0; 

	unless ( defined ( $target->{'maxcalls'} ) ) { 
		return 0; 
	}
	if ( $target->{'maxcalls'} =~ /auto/i ) { 
		if ( defined ( $target->{'queue'} ) ) { 
			my $free_operators = $this->_get_free_operators( $target->{'queue'} );
			if ( $free_operators < 0 ) { 
				$this->log ("error", "Queue ".$target->{'queue'}." is empty. Do not call."); 
                print "Queue ".$target->{'queue'}." is empty. Do not call.\n"; 
			}
			if ( $free_operators == 0 ) { 
				$this->log ("info", "Queue".$target->{'queue'}. " is busy. But let's call predictive."); 
			    print "Queue ".$target->{'queue'}. " is busy. But let's call predictive.\n";
            }

			if ( $free_operators >= 0 ) { 
				if ( $target->{'predictive_calls'} ) { 
					$count_of_calls = $free_operators + $target->{'predictive_calls'}; 
                    print "Count of calls ($count_of_calls) = free operators ($free_operators) + predictive (". 
                        $target->{'predictive_calls'}. ")\n";
				}
			}
            print "_get_count_of_calls() returns $count_of_calls \n";
			return $count_of_calls; 
		}
	}
	return $target->{'maxcalls'}; 
}

sub _get_free_operators { 
	my ($this, $queuename) = @_; 

    # Empty Queue case
    unless ( defined ( $this->{'queuemembers'} ) ) { 
        return -1; # No such queuemembers ВААЩЕ!    
    }
    unless ( defined ( $this->{'queuemembers'}->{$queuename} ) ) { 
        return -1; # Empty Queue 
    }
    unless ( defined ( $this->{'queuemembers'}->{$queuename}->{'queue_operators'} ) ) { 
        return -1; # Empty Queue; 
    }
	if ( $this->{'queuemembers'}->{$queuename}->{'queue_operators'} <= 0 ) { 
		return -1; # Empty Queue; 
	}

    # No free operators case 
    unless ( $this->{'queuemembers'}->{$queuename}->{'free_operators'} ) { 
        return 0; # No free operators
    }
	if ( $this->{'queuemembers'}->{$queuename}->{'free_operators'} == 0 ) { 
		return 0; 
	}

    # Success case 
	return $this->{'queuemembers'}->{$queuename}->{'free_operators'};
}

sub _get_queue_status { 
	my ($this) = @_; 

	unless ( $this->{manager_connected} ) { 
		 unless ( $this->_manager_connect() ) {  
			$this->log("error","Can't connect to manager."); 
			die "Can't connect to manager.\n"; 
		}
	}  

	my $sent = $this->{manager}->sendcommand( 'Action' => 'QueueStatus' );
    unless ( defined( $sent ) ) {
        $this->log( "warning",
            "Can't send the command QueueStatus: " . $this->{manager}->geterror() );
        return undef;
    }

    my $reply = $this->{manager}->receive_answer();
    unless ( defined($reply) ) {
        $this->log( "warning",
            "Can't receive the answer:" . $this->{manager}->geterror() );
        return undef;
    }

    my $status = $reply->{'Response'};
    unless ( defined($status) ) {
        $this->log( "warning", "Answer does not contain 'Response' field." );
        return undef;
    }
    if ( $status ne 'Success' ) {
        $this->log( "warning", "Response not success: " . $status );
        return undef;
    }

	# reading from socket while did not receive Event: StatusComplete
    my @replies;
    while (1) {
        my $reply = $this->{manager}->receive_answer();
        unless ( defined($reply) ) {
            next;
        }
        unless ($reply) {
            next;
        }
        $status = $reply->{'Event'};
        if ( $status eq 'QueueStatusComplete' ) {
            last;
        }
        push @replies, $reply;
    }

    # warn Dumper (\@replies);
    foreach my $reply (@replies) {
        if ( $reply->{'Event'} =~ /QueueMember/ ) {
        	my $queuename = $reply->{'Queue'}; 
        	unless ( defined ( $this->{'queuemembers'}->{$queuename} ) ) { 
        		$this->{'queuemembers'}->{$queuename}->{'free_operators'} = 0; 
        		$this->{'queuemembers'}->{$queuename}->{'queue_operators'} = 0; 
          	}
			if ($reply->{'Status'} != 5 ) { 
                $this->{'queuemembers'}->{$queuename}->{'queue_operators'} += 1;	
                # $queue_operators = $queue_operators + 1;
			}
            if ( $reply->{'Status'} == 1 ) {
            	$this->{'queuemembers'}->{$queuename}->{'free_operators'} += 1; 
                # $free_operators = $free_operators + 1;
            }
        }
    }

}

sub _manager_connect { 
	my ($this) = @_; 

	# Set Asterisk Parameters
    my $astManagerHost   = $this->{conf}->{'asterisk'}->{'astManagerHost'};
    my $astManagerPort   = $this->{conf}->{'asterisk'}->{'astManagerPort'};
    my $astManagerUser   = $this->{conf}->{'asterisk'}->{'astManagerUser'};
    my $astManagerSecret = $this->{conf}->{'asterisk'}->{'astManagerSecret'};

    my $astManager = NetSDS::Asterisk::Manager->new(
        host     => $astManagerHost,
        port     => $astManagerPort,
        username => $astManagerUser,
        secret   => $astManagerSecret,
        events   => 'Off',
    );

    my $connected = $astManager->connect();
    unless ( defined($connected) ) {
        $this->log( "warning",
            "Can't connect to the asterisk: " . $astManager->geterror() );
        return undef;
    }

    
    $this->{'manager_connected'} = 1; 
    $this->{manager} = $astManager; 

    return 1; 

}

sub _target_db_connect { 
	my ($this, $target, $target_name) = @_; 

	my $dsn = $target->{'dsn'}; 
	my $login = $target->{'login'}; 
	my $passwd = $target->{'passwd'}; 

	my $dbh = NetSDS::DBI->new (
            dsn    => $dsn,
            login  => $login,
            passwd => $passwd,
            attrs  => { RaiseError => 1, AutoCommit => 1 },
    ); 

	unless ( $dbh ) { 
		die "Could not connect to $dsn : $login \n"; 
	}

	# Checks for table exists
    my $table = $target->{'table'};
    my $sth   = $dbh->call( "select count(*) from " . $table );
    my $row   = $sth->fetchrow_hashref();
    unless ( defined($row) ) {
        # table does not exist;
        $this->log( "error", "Table $table does not exist." );
        die;
    }

	$this->{targets}->{$target_name}->{dbh} = $dbh;
	return 1; 
}

sub _connect_event_listener { 
 	my ($this) = @_; 

    # Set Asterisk Parameters
    my $astManagerHost   = $this->{conf}->{'asterisk'}->{'astManagerHost'};
    my $astManagerPort   = $this->{conf}->{'asterisk'}->{'astManagerPort'};
    my $astManagerUser   = $this->{conf}->{'asterisk'}->{'evtManagerUser'};
    my $astManagerSecret = $this->{conf}->{'asterisk'}->{'evtManagerSecret'};

    unless ( defined ( $astManagerHost) ) { die "astManagerHost is undefined in config.\n"; }
    unless ( defined ( $astManagerPort) ) { die "astManagerPort is undefined in config.\n"; }
    unless ( defined ( $astManagerUser) ) { die "evtManagerUser is undefined in config.\n"; }
    unless ( defined ( $astManagerSecret ) ) { die "evtManagerSecret is undefined in config.\n"; }

    # Set Event Listener
    my $event_listener = NetSDS::Asterisk::EventListener->new(
        host     => $astManagerHost,
        port     => $astManagerPort,
        username => $astManagerUser,
        secret   => $astManagerSecret
    );

    my $el_connected = $event_listener->_connect();
    unless ( defined($el_connected) ) {
        $this->log( "error",
            "Can't connect to asterisk via $astManagerHost:$astManagerPort" );  
        $this->log( "error", $event_listener->{'error'} );
        die "Can't connect to asterisk: " . $event_listener->{'error'};
    }

    $this->{el} = $event_listener;
    return 1; 
}



=item B<is_target_correct> 

 This method checks given target for all required parameters. Like dsn, context, table. 

=cut 
sub is_target_correct { 
	my ($this, $target, $target_name) = @_; 

  	unless ( defined ( $target->{'context'} ) ) { 
		$this->log ("info","The target '".$target_name."' does not have any context."); 
    	return undef; 
	}

	unless ( defined ( $target->{'dsn'} ) ) { 
		$this->log ("info","The target '".$target_name."' does not have DSN "); 
		return undef; 
	} 

	unless ( defined ( $target->{'login'} ) ) { 	
		$this->log ("info","The target '".$target_name."' does not have login "); 
		return undef 
	}

	unless ( defined ( $target->{'passwd'} ) ) { 	
		$this->log ("info","The target '".$target_name."' does not have passwd "); 
		return undef 
	}

	unless ( defined ( $target->{'table'} ) ) { 
		$this->log ("info","The target '".$target_name."' does not have TABLE name. "); 
	    return undef; 
	} 

	return 1; 
}


#####################################################################################################
#####################################################################################################
#####################################################################################################
#####################################################################################################
#####################################################################################################

sub _join_variables_from_userfield {
    my $this      = shift;
    my $userfield = shift;
    my $id        = shift;

    if ( defined($userfield) ) {
        $userfield =~ s/&/|/g;
    }
    $userfield .= '|ID=' . $id;

    return $userfield;
}

sub _increment_tries {
    my $this   = shift;
    my $record = shift;

    my $id    = $record->{'id'};
    my $dest  = $record->{'destination'}; 
    my $target_name = $record->{'target_name'};

    my $table = $this->{conf}->{targets}->{$target_name}->{'table'};

    if ( $this->{debug} ) { print "Increment tries for $id:$dest in table $table\n"; }
    $this->log("info","Increment tries for $id:$dest in table $table");

    my $strQuery =
      "update $table set when_last_try=now(), tries=tries+1 where id=$id";

    $this->{targets}->{$target_name}->{dbh}->call($strQuery);

    return 1;
}

sub _add_signal_handlers {
    my $this = @_;

    $SIG{INT} = sub {
        die "SIGINT";
    };

    $SIG{TERM} = sub {
        die "SIGTERM"; 
    };

}

sub _is_my_call { 
    my ($this, $event) = @_; 

    unless ( defined ( $event->{'ActionID'} ) ) { 
        return undef; 
    } 

    my $actionId = $event->{'ActionID'};
    unless ( defined ( $this->{originated}->{$actionId} ) ) { 
        return undef; 
    }
    
    return 1; 
}

sub _hangup { 
    my ($this, $event) = @_; 

    #warn Dumper ($event); 

    my $channel = $event->{'Channel'}; 
    # warn Dumper ($channel, $this->{originated}); 

    foreach my $actionId ( keys %{$this->{originated}} ) {
        my $originated = $this->{originated}->{$actionId}; 
        unless ( defined ( $originated->{'channel'} ) ) { 
            next; 
        }

        #warn Dumper ( $originated->{'channel'} ); 
        if ( $channel =~ /$originated->{'channel'}/ ) { 
            return $originated; 
        }
    }
    return undef; 
}

sub _masquerade {
    my ($this, $event) = @_; 
    my $original = $event->{'Original'};
    my $clone = $event->{'Clone'}; 

    if ($this->{debug} ) { 
        printf ("Masquerade %s -> %s\n", $original, $clone); 
    }
    $this->log("info",sprintf("Masquerade %s -> %s\n", $original, $clone));

    foreach my $actionId ( keys %{$this->{originated}} ) {
        my $originated = $this->{originated}->{$actionId}; 
        unless ( defined ( $originated->{'channel'} ) ) { 
            next; 
        }
        if ( $original eq $originated->{'channel'} ) { 
            $this->{'originated'}->{$actionId}->{'channel'} = $clone; 
            return $originated; 
        }
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

