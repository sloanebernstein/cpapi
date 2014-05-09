#!/usr/local/cpanel/3rdparty/bin/perl
# cpanel - cpapi.pl             Copyright(c) 2014 cPanel, Inc.
#                                                           All rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited
use strict;

use LWP::UserAgent;

# Because having a certificate installed on 'localhost' is kinda dumb,
# I'm not wasting time with HTTPS.
# use LWP::Protocol::https;
use HTTP::Cookies;
use IO::Prompt;
use Data::Dumper;
use Encode qw( encode_utf8 );
use MIME::Base64;
use utf8;

# Presented output should be presentable.
use JSON;

use Getopt::Long;

# TODO: Most or all of these globals should go away.
my $username;
my $hostname = 'localhost';
my $protocol = 'http';
my $password;
my $accesshash_name = '/root/.accesshash';
my $debug;

my $call_name;
my @call_params;

my $api_class;
my $module;
my $function;

my $security_token;

my $uapi_regex       = qr/^uapi$/i;
my $whm_api_regex    = qr/^whm[01]$/i;
my $cpanel_api_regex = qr/^api[12]$/i;

GetOptions(
    'username|u=s' => \$username,
    'password|p'   => sub {
        local @ARGV = ();
        $password = prompt( "Password: ", -e => "*" );
        return 1;
    },
    'debug|d'        => \$debug,
    'accesshash|a=s' => \$accesshash_name,
    '<>'             => \&process_non_option,
);

my $useragent = LWP::UserAgent->new(
    cookie_jar            => HTTP::Cookies->new,
    requests_redirectable => [ 'GET', 'HEAD' ],
);

# At this point, we know which API we're talking to.
# We have a username and password argument.
# We can set up authentication as necessary.

if ( $api_class =~ $whm_api_regex ) {
    auth_for_whm( $useragent, $username, $password, $accesshash_name );
}
elsif ( $api_class =~ $cpanel_api_regex || $api_class =~ $uapi_regex ) {
    auth_for_cp( $useragent, $username, $password, $accesshash_name );
}
else { die "Couldn't make head or tails of the API class.\n"; }

my $url = assemble_url(
    'protocol'       => $protocol,
    'hostname'       => $hostname,
    'api_class'      => $api_class,
    'security_token' => $security_token,
    'module'         => $module,
    'function'       => $function,
    'username'       => $username,
    'params_ref'     => \@call_params,
);

if ($debug) { print "    request URL turned out to be $url\n"; }

my $response = $useragent->get($url);
my $json_printer = JSON->new->pretty;
#print $response->decoded_content . "\n\n\n";
print $json_printer->encode( decode_json( encode_utf8( $response->decoded_content ) ) );

##################################################################################################################
#### Turning our inputs into what we can use
##################################################################################################################

# Expects something that Getopt::Long doesn't know how to handle.
# Returns 1.
sub process_non_option {
    my ( $opt_name, $opt_value ) = @_;
    if ($debug) { print "entered process_non_option\n"; }
    if ( $opt_name =~ /::/ ) {
        ( $api_class, $module, $function ) = process_call_name($opt_name);
    }
    elsif ( $opt_name =~ /=/ ) {
        push @call_params, process_parameter($opt_name);
    }
    else {
        print "I don't understand $opt_name. I'm ignoring it.\n";
    }
    return 1;
}

# Expects the part of @ARGV that represents which API call we are making.
# Something with names separated by ::
# Returns API class, module, and function name.
sub process_call_name {
    my ($call) = @_;
    if ($debug) { print "entered process_call_option\n"; }
    my @call_parts = split '::', $call;
    my ( $api_class, $module, $function );
    if ( $call_parts[0] =~ $uapi_regex ) {
        $api_class = shift @call_parts;
        $function  = pop @call_parts;
        $module    = join( '/', @call_parts, '' );
    }
    elsif ( $call_parts[0] =~ $whm_api_regex || $call_parts[0] =~ $cpanel_api_regex ) {
        ( $api_class, $module, $function ) = @call_parts;
    }
    else { die 'API version is not clear. Use UAPI, API1, API2, WHM0, or WHM1.'; }
    return ( $api_class, $module, $function );
}

# Expects one parameter passed to the program. Where appropriate, prompts
# for the value, then returns a parameter that can go into the URL.
sub process_parameter {
    my ($arg) = @_;
    if ($debug) { print "entered process_parameter\n"; }
    if ( $arg =~ /^[^=]+=[^=]+$/ ) {
        return $arg;
    }
    elsif ( $arg =~ /^=/ ) {

        # We were passed something like '=foo' which is meaningless.
        die "A parameter has no name. Did you misplace a space?\n";
    }
    else {
        my $value;
        $value = prompt("$arg: ");
        return "$arg=$value";
    }
}

##################################################################################################################
#### Authorizing our UserAgent
##################################################################################################################

# Expects four arguments:
#   $useragent       - an LWP::UserAgent object
#   $username        - Defaults to 'root'
#   $password        - If you're not providing it, leave it false
#   $accesshash_name - a filename. Defaults to /root/.accesshash
# Returns 1 for success, or 0 if no authentication method succeeded.
sub auth_for_whm {
    my ( $useragent, $username, $password, $accesshash_name ) = @_;
    if ($debug) { print "entered auth_for_whm\n"; }
    die "No useragent provided. How did you get here?" unless $useragent;
    $username ||= 'root';

    simple_auth_via_hash( $useragent, $username, $accesshash_name )
      or auth_via_password( $useragent, $username, $password )
      or die "WHM-style authentication failed.\n";
}

sub auth_for_cp {
    my ( $useragent, $username, $password, $accesshash_name ) = @_;
    if ($debug) { print "entered auth_for_cp\n"; }
    die "No useragent provided. How did you get here?" unless $useragent;
    die "cPanel API calls need a username.\n"          unless $username;

    if ( simple_auth_via_password( $useragent, $username, $password ) ) {
        $security_token = '/';
        return 1;
    }
    if ($debug) { print "    Attempting cPanel user auth via root access hash.\n"; }

    my $accesshash = read_access_hash($accesshash_name);
    die "cPanel auth via hash failed\n" unless get_security_token( $username, $accesshash );
}

sub simple_auth_via_hash {
    my ( $useragent, $username, $accesshash_name ) = @_;
    if ($debug) { print "entered simple_auth_via_hash\n"; }
    $accesshash_name ||= '/root/.accesshash';

    my $accesshash = read_access_hash($accesshash_name);
    return 0 unless $accesshash;
    if ($debug) { print "    Access hash used for authentication.\n"; }
    $useragent->default_header( 'Authorization' => 'WHM ' . $username . ':' . $accesshash, );
}

sub simple_auth_via_password {
    my ( $useragent, $username, $password ) = @_;
    if ($debug) { print "entered simple_auth_via_passwd\n"; }
    if ( !$username || !$password ) { return 0; }

    if ($debug) { print "    Password used for authentication.\n"; }
    $useragent->default_header( 'Authorization' => 'BASIC ' . MIME::Base64::encode( $username . ':' . $password ), );
    return 1;
}

# TODO: Need to make sure the access hash is valid.
sub read_access_hash {
    my ($accesshash_name) = @_;
    if ($debug) {
        print "entered read_access_hash\n";
        print "    read_access_hash got $accesshash_name\n";
    }
    my $accesshash;

    # TODO: This is probably the wrong thing to do.
    open my $accesshash_fh, '<', $accesshash_name or return undef;
    while (<$accesshash_fh>) {
        chomp;
        $accesshash .= $_;
    }
    close $accesshash_fh;
    if ($debug) { print "    access hash is " . length($accesshash) . " characters long.\n"; }
    return $accesshash;
}

##################################################################################################################
#### Populating $security_token
##################################################################################################################

# Expects an API version and valid cPanel username.
#     MAKES A WHM API CALL
# to generate a user session, then returns the security token for that session.
# Currently does not check for or handle error conditions, like users that
# don't exist.
sub get_security_token {
    my ( $cpanel_username, $accesshash ) = @_;
    if ($debug) {
        print "entered get_security_token\n";
        print "    got username $cpanel_username\n";
    }
    return 0 unless $cpanel_username;
    return 0 unless $accesshash;

    # TODO: Maybe access hash is bad. Gotta deal with that.
    my $localuseragent = LWP::UserAgent->new(
        cookie_jar            => HTTP::Cookies->new,
        requests_redirectable => []
    );
    $localuseragent->default_header( 'Authorization' => 'WHM root:' . $accesshash, );

    my $request         = "/json-api/create_user_session?api.version=1&user=${cpanel_username}&service=cpaneld";
    my $response        = $localuseragent->post( "http://${hostname}:2086" . $request, );
    my $decoded_content = decode_json( $response->decoded_content );
    my $session_url     = $decoded_content->{'data'}->{'url'};

    # LWP will bomb out with a certificate problem if we use HTTPS, so we have to use plain HTTP.
    $session_url    = force_http($session_url);
    $session_url =~ m{(cpsess[^/]+)};
    $security_token = "$1/";
    if ($debug) { print "    security_token turned out to be $security_token\n"; }
    $response       = $useragent->get($session_url);

    # global $security_token is now populated
    return 1;
}

# Accepts a URL in HTTP or HTTPS, and returns it in HTTP.
sub force_http {
    my ($url) = @_;
    $url =~ s/https:/http:/;
    $url =~ s/:2083/:2082/;
    return $url;
}

##################################################################################################################
#### Assembling our request URL
##################################################################################################################

# Expects a hash of arguments. {
#   'protocol'       => defaults to http (and really shouldn't be changed right now)
#   'hostname'       => defaults to localhost (ditto)
#   'api_class'      => one of uapi, api1, api2, whm0, or whm1
#   'security_token' => /cpsessXXXXXXXXXX/ or '' or undef
#   'module'         => the module within which the function you want resides
#   'function'       => the function you want to call
#   'username'       => for api1 and api2 calls, a username needs to be specified
#   'params_ref'     => an array of arguments to the API call.
# }
# Returns the URL of the API call, not including arguments to that call.
sub assemble_url {
    my %args = @_;

    if ($debug) {
        print "entered assemble_url\n";
        foreach ( sort keys %args ) { print "    assemble_url args $_ => " . $args{$_} . "\n"; }
    }

    my %parts = (
        'protocol'              => $args{'protocol'},
        'hostname'              => $args{'hostname'},
        'port'                  => whatis_port( $args{'api_class'} ),
        'json-api'              => is_jsonapi( $args{'api_class'} ),
        'security_token'        => $args{'security_token'},
        'execute'               => is_execute( $args{'api_class'} ),
        'cpanel'                => is_cpanel( $args{'api_class'} ),
        'user'                  => get_cpanel_userarg( $args{'api_class'}, $args{'username'} ),
        'cpanel_jsonapi_module' => is_cpanel_jsonapi_module( $args{'api_class'} ),
        'module'                => $args{'module'},
        'cpanel_jsonapi_func'   => is_cpanel_jsonapi_func( $args{'api_class'} ),
        'function'              => $args{'function'},
        'api_version'           => api_version( $args{'api_class'} ),
    );

    my $url;
    $url = "$parts{'protocol'}://$parts{'hostname'}:$parts{'port'}/";
    $url .= join '',  @parts{qw/ security_token json-api execute cpanel user cpanel_jsonapi_module module cpanel_jsonapi_func function api_version /};
    $url .= join '&', @{ $args{'params_ref'} };

    return $url;
}

# These subroutines take the API class ( whm0, whm1, api1, api2, uapi ) and
# return a string if it needs to be in the URL. Empty is correct in some cases.
sub whatis_port {
    my ($api_class) = @_;
    return $api_class =~ $whm_api_regex ? 2086 : 2082;
}

sub is_jsonapi {
    my ($api_class) = @_;
    return $api_class =~ $uapi_regex ? '' : 'json-api/';
}

sub is_execute {
    my ($api_class) = @_;
    return $api_class =~ $uapi_regex ? '/execute/' : '';
}

sub is_cpanel {
    my ($api_class) = @_;
    return $api_class =~ $cpanel_api_regex ? 'cpanel?' : '';
}

sub get_cpanel_userarg {
    my ( $api_class, $username ) = @_;
    return $api_class =~ $cpanel_api_regex ? "user=$username" : '';
}

sub is_cpanel_jsonapi_module {
    my ($api_class) = @_;
    return $api_class =~ $cpanel_api_regex ? '&cpanel_jsonapi_module=' : '';
}

sub is_cpanel_jsonapi_func {
    my ($api_class) = @_;
    return $api_class =~ $cpanel_api_regex ? '&cpanel_jsonapi_func=' : '';
}

sub api_version {
    my ($api_class) = @_;
    $api_class = lc $api_class;
    my %results = (
        'whm0' => '?api.version=0&',
        'whm1' => '?api.version=1&',
        'api1' => '&cpanel_jsonapi_version=1&',
        'api2' => '&cpanel_jsonapi_version=2&',
        'uapi' => '?'
    );
    return $results{$api_class};
}
