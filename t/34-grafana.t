#!/usr/bin/env perl

use warnings;
use strict;
use Test::More;
use Sys::Hostname;

BEGIN {
    use lib('t');
    require TestUtils;
    import TestUtils;
    use FindBin;
    use lib "$FindBin::Bin/lib/lib/perl5";
}

plan( tests => 88 );

##################################################
# create our test site
my $omd_bin = TestUtils::get_omd_bin();
my $site    = TestUtils::create_test_site() or TestUtils::bail_out_clean("no further testing without site");
my $auth    = 'OMD Monitoring Site '.$site.':omdadmin:omd';
my $curl    = '/usr/bin/curl -v --user omdadmin:omd --noproxy \* ';
my $ip      = TestUtils::get_external_ip();

TestUtils::test_command({ cmd => $omd_bin." config $site set GRAFANA on" });
TestUtils::test_command({ cmd => $omd_bin." start $site", like => '/Starting Grafana...OK/' });

#grafana interface
TestUtils::test_url({ url => 'http://localhost/'.$site.'/grafana/', waitfor => '<title>Grafana<\/title>', auth => $auth });
TestUtils::test_command({ cmd => "/bin/su - $site -c 'lib/nagios/plugins/check_http -t 60 -H 127.0.0.1 -p 8003 -k \"X-WEBAUTH-USER: omdadmin\" -s \"<title>Grafana</title>\"'", like => '/HTTP OK:/' });
TestUtils::test_command({ cmd => "/omd/sites/$site/lib/nagios/plugins/check_http -t 60 -H localhost -a omdadmin:omd -u '/$site/grafana/' -s '\"login\":\"omdadmin\"'", like => '/HTTP OK:/' });

#grafana interface with ssl
TestUtils::test_command({ cmd => $omd_bin." stop $site", like => '/Stopping Grafana/' });
TestUtils::test_command({ cmd => $omd_bin." config $site set APACHE_MODE ssl", like => '/^$/' });
TestUtils::test_command({ cmd => $omd_bin." start $site", like => '/Starting Grafana/' });
TestUtils::restart_system_apache();
TestUtils::test_command({ cmd => "/omd/sites/$site/lib/nagios/plugins/check_http -t 60 -H localhost -S -a omdadmin:omd -u '/$site/grafana/' -s '\"login\":\"omdadmin\"'", like => '/HTTP OK:/' });

TestUtils::test_command({ cmd => $omd_bin." stop $site" });

#grafana interface with ssl and thruk cookie auth
my $sessionid = TestUtils::create_fake_cookie_login($site);
TestUtils::test_command({ cmd => $omd_bin." config $site set THRUK_COOKIE_AUTH on", like => '/^$/' });
TestUtils::test_command({ cmd => $omd_bin." start $site", like => '/Starting Grafana/' });
TestUtils::test_command({ cmd => "/omd/sites/$site/lib/nagios/plugins/check_http -t 60 -H localhost -S -k 'Cookie: thruk_auth=$sessionid' -u '/$site/grafana/' -s '\"login\":\"omdadmin\"'", like => '/HTTP OK:/' });

#grafana interface with http and thruk cookie auth
TestUtils::test_command({ cmd => $omd_bin." stop $site" });
TestUtils::test_command({ cmd => $omd_bin." config $site set APACHE_MODE own", like => '/^$/' });
TestUtils::restart_system_apache();
TestUtils::test_command({ cmd => $omd_bin." start $site", like => '/Starting Grafana/' });
TestUtils::test_command({ cmd => "/omd/sites/$site/lib/nagios/plugins/check_http -t 60 -H localhost -k 'Cookie: thruk_auth=$sessionid' -u '/$site/grafana/' -s '\"login\":\"omdadmin\"'", like => '/HTTP OK:/' });


# make sure grafana listens to localhost only
# first test against localhost and make sure it works
TestUtils::test_command({ cmd => "/bin/su - $site -c '$curl \"http://127.0.0.1:8003/$site/grafana\" -H \"X-WEBAUTH-USER: omdadmin\" '",
                          errlike => ['/Set-Cookie: grafana_sess/'], 
                          like  => ['/"login":"omdadmin"/'],
                       });
# then test external ip and make sure it doesnt work
TestUtils::test_command({ cmd => "/bin/su - $site -c '$curl \"http://$ip:8003/$site/grafana\" -H \"X-WEBAUTH-USER: omdadmin\" '",
                          errlike => ['/(Failed to connect|Connection refused)/'], 
                          unlike  => ['/"login":"omdadmin"/'],
                          exit    => undef,
                       });

TestUtils::test_command({ cmd => $omd_bin." stop $site" });
TestUtils::remove_test_site($site);

