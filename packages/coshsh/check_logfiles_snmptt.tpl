# {{ mib.mib }} {{ mib.miblabel }}

use Monitoring::Trap::HostSNMPTrapinfo;

my $VERBOSE = 0;
our @commands = ();

sub prepare_submit_command {
  my ($address, $mib, $trap, $severity, $text) = @_;
  $text =~ s/[^[:ascii:]]//g;
  $trap =~ s/[^[:ascii:]]//g;;
  if (my $info = Monitoring::Trap::HostSNMPTrapinfo::get_host_from_ip($address, $mib)) {
{#
    Sowas ist moeglich. Der Host implementiert die alte Mib, seine Traps werden also
    vom trapfile-Scanner ISILON-TRAP-2014-MIB entdeckt.
    Seine Services lauten aber ...traps_ISILON-TRAP-MIB_..., daher muss get_host_from_ip
    auch die Alias-Mib [2] liefern.
    '10.145.60.67' => {
        'ISILON-TRAP-2014-MIB' => ['itaemc01c1.bmwgroup.net', 'os_isilon', 'ISILON-TRAP-MIB'],
    },

#}
    my $command = sprintf "COMMAND [%d] PROCESS_SERVICE_CHECK_RESULT;%s;%s;%d;%s",
        time, $info->[0],
        $info->[1].'_traps_'.$info->[2].'_'.$trap,
        $severity,
        $text;
    push(@commands, $command);
  }
  return $text;
}

sub snmptt_resolve {
  my ($sys, $text, $subtraps) = @_;
  #my @subtraps = map { /^[\d\.]+\s+"*(.*?)"*$/; $1; } split(/____/, $subtraps);
  my @subtraps = map { /^[\d\.]+\s+(.*)$/; $1; } split(/____/, $subtraps);
  my $subtraps = join(", ", @subtraps);
  foreach my $index (1..scalar(@subtraps)) {
    $text =~ s/\$$index/$subtraps[$index-1]/g;
  }
  $text =~ s/\$\*/$subtraps/g;
  return $text;
}

sub match_matches {
  my ($mode, $rules, $subtraps) = @_;
  my @rules = split("____", $rules);
  #my @subtraps = map { /^[\d\.]+\s+"*(.*?)"*$/; $1; } split(/____/, $subtraps);
  my @subtraps = map {
    # .... "____.1.3.6.1.4.1.1139.102.0.1.2 "Info"____.1.3.6....
    # uebrig bleibt Info ohne Anfuehrungszeichen
    if (/^"(.*)"$/) {
      $1;
    } else {
      $_;
    }
  } map {
      /^[\d\.]+\s+(.*)$/; $1;
  } split(/____/, $subtraps);
  my $rulehits = 0;
  foreach my $rule (@rules) {
    if ($rule =~ /^\$(\d+):\s*!\s*(\w+)/) {
      # MATCH $x: ! n
      $rulehits +=1 if $subtraps[$1-1] ne $2;
    } elsif ($rule =~ /^\$(\d+):\s*(\w+)/) {
      # MATCH $x: n
      $rulehits +=1 if $subtraps[$1-1] eq $2;
    } elsif ($rule =~ /^\$(\d+):\s*!\s*\((.*)\)\s*i\*$/) {
      # MATCH $x: ! (reg) i
      $rulehits += 1 if $subtraps[$1-1] !~ /$2/i;
    } elsif ($rule =~ /^\$(\d+):\s*!ş*\((.*)\)\s*$/) {
      # MATCH $x: ! (reg)
      $rulehits += 1 if $subtraps[$1-1] !~ /$2/;
    } elsif ($rule =~ /^\$(\d+):\s*\((.*)\)\s*i\s*$/) {
      # MATCH $x: (reg) i
      $rulehits += 1 if $subtraps[$1-1] =~ /$2/i;
    } elsif ($rule =~ /^\$(\d+):\s*\((.*)\)\s*$/) {
      # MATCH $x: (reg)
      $rulehits += 1 if $subtraps[$1-1] =~ /$2/;
    } elsif ($rule =~ /^\$(\d+):\s*!\s*<\s*(\d+)\s*$/) {
      # MATCH $x: ! < n
      $rulehits += 1 if $subtraps[$1-1] >= $2;
    } elsif ($rule =~ /^\$(\d+):\s*<\s*(\d+)\s*$/) {
      # MATCH $x: < n
      $rulehits += 1 if $subtraps[$1-1] < $2;
    } elsif ($rule =~ /^\$(\d+):\s*!\s*>\s*(\d+)\s*$/) {
      # MATCH $x: ! > n
      $rulehits += 1 if $subtraps[$1-1] <= $2;
    } elsif ($rule =~ /^\$(\d+):\s*>\s*(\d+)\s*$/) {
      # MATCH $x: > n
      $rulehits += 1 if $subtraps[$1-1] > $2;
    } elsif ($rule =~ /^\$(\d+):\s*!\s*(\d+)-(\d+)\s*$/) {
      # MATCH $x: ! n-n
      $rulehits += 1 if $subtraps[$1-1] < $2 || $subtraps[$1-1] > $3;
    } elsif ($rule =~ /^\$(\d+):\s*(\d+)-(\d+)\s*$/) {
      # MATCH $x: n-n
      $rulehits += 1 if $subtraps[$1-1] >= $2 && $subtraps[$1-1] <= $3;
    } else {
printf STDERR "unknown rule __%s__\n", $rule;
    }
  }
  return 1 if $mode eq 'and' && $rulehits == scalar(@rules); # all of them
  return 1 if $mode eq 'or' && $rulehits; # any of them
  return 0;
}

$options = 'report=long,supersmartpostscript';

@searches = (
{% for event in mib.events %}
{
  tag => '{{ event.name }}',
  logfile => $ENV{OMD_ROOT}.'/var/log/snmp/traps.log',
  rotation => '^%s\.((1)|([2-9]+\.gz))$',
  criticalpatterns => '^\[(.*?)\] summary: .*UDP: \[([\.\d]+)\].*?____([\.\d]+ .*?)____\.1\.3\.6\.1\.6\.3\.1\.1\.4\.1\.0 [\.]*{{ event.oid }}____(.*)$',
  script => sub {
    my $address = $ENV{CHECK_LOGFILES_CAPTURE_GROUP2};
    my $flat_trap = $ENV{CHECK_LOGFILES_CAPTURE_GROUP.$ENV{CHECK_LOGFILES_CAPTURE_GROUPS}};
    my $severity = undef;
    my $resolved_text = undef;
{% if event.matches %}
{%   for match in event.matches %}
{%     if loop.first %}
    if (match_matches('{{ match[1] }}', '{{ match[2] }}', $flat_trap)) {
        $resolved_text = snmptt_resolve($address, '{{ match[3] }}', $flat_trap)." - match {{ match[2].replace('$', 'DLR') }}";
        $severity = {{ match[0] }};
{%     else %}
    } elsif (match_matches('{{ match[1] }}', '{{ match[2] }}', $flat_trap)) {
        $resolved_text = snmptt_resolve($address, '{{ match[3] }}', $flat_trap)." - match {{ match[2].replace('$', 'DLR') }}";
        $severity = {{ match[0] }};
{%     endif %}
{%     if loop.last %}
    }
{%     endif %}
{%   endfor %}
{% endif %}
    if (! defined $severity) {
      # there are no sub-events at all or none of them matched
      $resolved_text = snmptt_resolve($address, '{{ event.text }}', $flat_trap);
      $severity = {{ event.nagioslevel }}
    }
    my $sub =  prepare_submit_command($address, '{{ mib.mib }}', '{{ event.name }}', $severity, $resolved_text);
    printf "sub %s\n", $sub;
    return 2;
  },
  options => 'supersmartscript,capturegroups,noprotocol,noperfdata',
},
{% endfor %}
{#
{
  tag => 'UnknownTraps',
  logfile => $ENV{OMD_ROOT}.'/var/log/snmp/traps.log',
  rotation => '^%s\.((1)|([2-9]+\.gz))$',
  criticalpatterns => '^\[(.*?)\] summary: .*UDP: \[([\.\d]+)\].*?____(.*)$',
  criticalexceptions => [
{% for event in mib.events %}
    '^\[(.*?)\] summary: .*UDP: \[([\.\d]+)\].*?____([\.\d]+ \d+)____\.1\.3\.6\.1\.6\.3\.1\.1\.4\.1\.0 [\.]*{{ event.oid }}____(.*)$',
{% endfor %}
  ],
  script => sub {
    my $address = $ENV{CHECK_LOGFILES_CAPTURE_GROUP2};
    my $flat_trap = $ENV{CHECK_LOGFILES_CAPTURE_GROUP.$ENV{CHECK_LOGFILES_CAPTURE_GROUPS}};
    if (my $info = Monitoring::Trap::HostSNMPTrapinfo::get_host_from_ip($address)) {
      print $flat_trap;
      return 2;
    } else {
      return 0; # unknown host, ignore
    }
  },
  options => 'supersmartscript,capturegroups,noprotocol,noperfdata',
}
#}
);

$postscript = sub {
  if (@commands) {
    my $submitted = 0;
    my $last_command = "";
    if (scalar(@commands)) {
      open SPOOL, ">".$ENV{OMD_ROOT}.'/tmp/{{ mib.mib }}.cmds';
      foreach (map { /COMMAND (.*)/; $1; } @commands) {
        if ($_ eq $last_command) {
          next;
        } else {
          printf SPOOL "%s\n", $_;
          $submitted++;
          $last_command = $_;
        }
      }
      close SPOOL;
      if ("{{ mib.extcmd }}" eq "nagios.cmd") {
        open CMD, ">".$ENV{OMD_ROOT}.'/tmp/run/nagios.cmd';
        printf CMD "[%lu] PROCESS_FILE;%s;1\n", time, $ENV{OMD_ROOT}.'/tmp/{{ mib.mib }}.cmds';
        close CMD;
      } elsif ("{{ mib.extcmd }}" eq "naemon.cmd") {
        open CMD, ">".$ENV{OMD_ROOT}.'/tmp/run/naemon.cmd';
        printf CMD "[%lu] PROCESS_FILE;%s;1\n", time, $ENV{OMD_ROOT}.'/tmp/{{ mib.mib }}.cmds';
        close CMD;
      }
      #open CMD, ">".$ENV{OMD_ROOT}.'/tmp/run/live';
    }
    if ($submitted) {
      printf "OK - found %d traps (%d submitted) | traps=%d submitted=%d\n", scalar(@commands), $submitted, scalar(@commands), $submitted;
      printf "%s\n", join("\n", @commands);
      return 0;
    } else {
      printf "OK - found %d traps, all of them were harmless\n", scalar(@commands);
      return 0;
    }
  } else {
    printf "OK - found no new traps | traps=0 submitted=0\n";
    return 0;
  }
};

