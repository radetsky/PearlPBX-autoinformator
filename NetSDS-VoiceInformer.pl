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

# Start 
# У нас есть N целей. Для каждой из них надо создать свой процесс. 

my @children; 

sub start { 
	my $this = shift;
  #warn Dumper ($this->{conf}); 
  # Для каждой цели запускаем свой процесс. 
	foreach my $target_name ( keys %{ $this->{conf}->{'targets'} } ) {  
		 my $target = $this->{conf}->{'targets'}->{$target_name}; 
		 # warn Dumper ($target);
		 my $is_target_correct = $this->is_target_correct($target, $target_name); 
		 unless ( defined ($is_target_correct ) ) { 
		 	$this->speak("[$$] The target called '".$target_name."' with these parameters is incorrect. Please RTFM! Ignoring it. "); 
			$this->speak("[$$] Parameters dump: " . Dumper ($target) ); 
			next;
		 }
		 my $child = $this->burn_child ($target, $target_name, $this->{conf});
		 push @children, $child; 
  } 

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
			tname => $target_name, 
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

# Ключевые слова для конфигурации 
# 1. Максимальное количество параллельных звонков ( для автооповещения ). 
# Варианты: 1. auto (если используется возврат в очередь) 
#           2. обсолютное значение от 1 до 10000. 
# 2. Маршрутизация звонков ( несмотря на то, что мы можем зароутить звонки через 
# локальный интерфейс Local/ и отправить по локальной маршрутизации, которая прописана 
#  в астериске - тут есть проблемы, связанные со скоростью обработки таких звонков через
# Asterisk Manager. Так что лучше по старинке - собственными средствами. 
# Для этого вводится таблица марштутизации с номерами CallerID и маршрутами, которые надо подставлять. 
# Пример: 
# <050> 
# callerid=0504139380
# trunk=SIP/MTS
# </050> 
# Вопрос по ситуации в ПлюсБанке, а как же группа пиров типа GSM/Шлюз ?
# Значит надо прописать группу trunk-ов c количеством возможных параллельных звонков по разным транкам
# <trunkgroup1>
# SIP/GSM1 = 1 
# SIP/GSM2 = 2
# SIP/MTS = 5 
# </trunkgroup1> 
# И в таком случае вмето транка, прописываем транкгруппу 
# <050> 
# callerid=0504139380 
# trunkgroup=trunkgroup1 
# </050>
# Так же еще надо прописать максимальное количество используемых каналов для каждого транка, даже если он не входит 
# в группу: 
# <trunk> 
# SIP/MTS=5 
# SIP/GSM1=1 
# SIP/GSM2=2 
# </trunk> 
# Соответственно в памяти ведем подсчет используемых каналов и не нарываемся на лишнее. 
# Функция поиска свободного канала сводится к перебору по схеме "цикл от начала до конца" 
# ------------------------------------
# 3. Пункт конфигурации - ЦЕЛИ! 
# Именно по Цели VoiceInformer знает откуда и по каким условиям брать списки звонков 
# И куда отправлять звонки 
# <targets> 
# <windication1>
# context=Windication-Incoming 
# maxcalls = auto
# queue = windication1
# dsn=db:asterisk
# table=predictive 
# where=userfield like 'GROUP=1%' order by id desc 
# </windication1>
# <dyatel> 
# context=WyDolzhnyDeneg
# maxcalls=10
# dsn=db:bankas 
# table=dolgi 
# where=order by priority 
# </dyatel> 
# <pora_na_rabotu>
# maxcalls=120
# context=Attention_Avaria
# dsn=db:work
# table=smena 
# where=
# </pora_na_rabotu>

# </targets> 

# Запуск процесса производится просто /opt/NetSDS/bin/NetSDS-VoiceInformer.pl
# Если в конфигурации прописано 5 целей (пять!), то главный процесс должен запустить пять
# потомков, с параметрами доступа к базам и астериску. Они сами будут отслеживать наличие данных 
# в своих источниках и писать логи/отчеты/делать паузу в звонках. 
# Занятость каналов между собой отслеживать через SHARED MEMORY. 

# По окончанию рабочего процесса (некому больше звонить,  в лог должен быть выведен отчет 
# КОЛИЧЕСТВО СОВЕРШЕННЫХ ЗВОНКОВ (попытки)  
# НАЧАЛО РАБОТЫ СЕАНСА (дата/время)
# КОНЕЦ РАБОТЫ СЕАНСА (дата/время)
# ДОЗВОНИЛИСЬ (количество раз) 
# НЕ ДОЗВОНИЛИСЬ (количество раз) 


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

