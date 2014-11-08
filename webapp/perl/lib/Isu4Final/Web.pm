package Isu4Final::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use Redis::Jet;
use File::Slurp;
use Sys::Hostname;
use HTTP::Tiny;

my $config = {
    assets_dir  => '/var/tmp/isucon4/assets',
    map_host2ip => {
#        isu18a => '203.104.111.152',
#        isu18b => '203.104.111.153',
#        isu18c => '203.104.111.154',
        isu18a => '10.11.54.152',
        isu18b => '10.11.54.153',
        isu18c => '10.11.54.154',
    },
    redis_server => '10.11.54.152:6379',
};

sub ads_dir {
    my $self = shift;
    my $dir = $self->root_dir . '/ads';
    mkdir $dir unless -d $dir;
    return $dir;
}

sub log_dir {
    my $self = shift;
    my $dir = $self->root_dir . '/logs';
    mkdir $dir unless -d $dir;
    return $dir;
}

sub advertiser_id {
    my ( $self, $c ) = @_;
    return $c->req->header('X-Advertiser-Id');
}

sub assets_dir {
    my $self = shift;
    my $dir = $config->{assets_dir};
    mkdir $dir unless -d $dir;
    return $dir;
}

my $redis;
sub redis {
    $redis ||= Redis::Jet->new(server => $config->{redis_server});
    return $redis;
}

sub ad_key {
    my ( $self, $slot, $id ) = @_;
    return "isu4:ad:${slot}-${id}";
}

sub asset_key {
    my ( $self, $slot, $id ) = @_;
    return "isu4:asset:${slot}-${id}";
}

sub advertiser_key {
    my ( $self, $id ) = @_;
    return "isu4:advertiser:$id";
}

sub slot_key {
    my ( $self, $slot ) = @_;
    return "isu4:slot:$slot";
}

sub next_ad_id {
    my $self = shift;
    $self->redis->command('incr', 'isu4:ad-next');
}

sub next_ad {
    my ( $self, $c ) = @_;
    my $slot = $c->args->{slot};
    my $key = $self->slot_key($slot);

    my ($id, $err)  = $self->redis->command('rpoplpush', $key, $key);
    unless ( $id ) {
        return undef;
    }

    my $ad = $self->get_ad($c, $slot, $id);
    if ( $ad ) {
        return $ad;
    }
    else {
        $self->redis->command('lrem', $key, 0, $id);
        $self->next_ad($c);
    }
}

sub get_ad {
    my ( $self, $c, $slot, $id ) = @_;
    my $key = $self->ad_key($slot, $id);
    my ($val, $err)  = $self->redis->command('hgetall', $key);

    return undef if $err;

    my %ad = @$val;
    return undef if !%ad;

    $ad{impressions} = int($ad{impressions});
    $ad{asset}       = $c->req->uri_for("/slots/${slot}/ads/${id}/asset")->as_string;
    $ad{counter}     = $c->req->uri_for("/slots/${slot}/ads/${id}/count")->as_string;
    $ad{redirect}    = $c->req->uri_for("/slots/${slot}/ads/${id}/redirect")->as_string;
    $ad{type}        = undef if $ad{type} eq '';
    return \%ad;
}

sub decode_user_key {
    my ( $self, $id ) = @_;
    return { gender => 'unknown', age => undef } unless $id;
    my ( $gender, $age ) = split '/', $id;
    return { gender => $gender eq '0' ? 'female' : $gender eq '1' ? 'male' : undef, age => int($age) };
}

sub value2int {
    my ($self, $val, $err) = @_;
    return {} if $err;
    my %hash = @$val;

    my $new_hash = {};
    while ( my ($key, $value) = each (%hash) ) {
        $new_hash->{$key} = int($value);
    }

    return $new_hash;
}

get '/' => sub {
    my ( $self, $c )  = @_;
    open my $in, $self->root_dir . '/public/index.html' or do {
        $c->halt(404);
    };
    $c->res->body(do { local $/; <$in> });
    close $in;
    return $c->res;
};

post '/slots/{slot:[^/]+}/ads' => sub {
    my ($self, $c) = @_;

    my $advertiser_id;
    unless ( $advertiser_id = $self->advertiser_id($c) ) {
        $c->halt(400);
    }

    my $slot  = $c->args->{slot};
    my $asset = $c->req->uploads->{'asset'};

    my $id  = $self->next_ad_id;
    my $key = $self->ad_key($slot, $id);

    my $asset_host = $config->{map_host2ip}{(hostname)};
    my $asset_key  = $self->asset_key($slot, $id);
    my $asset_url  = sprintf 'http://%s/assets/%s', $asset_host, $asset_key;

    $self->redis->command('hmset',
        $key,
        'slot'        => $slot,
        'id'          => $id,
        'title'       => $c->req->param('title'),
        'type'        => $c->req->param('type') || $asset->content_type || 'video/mp4',
        'advertiser'  => $advertiser_id,
        'destination' => $c->req->param('destination'),
        'impressions' => 0,
        'clicks'      => 0,
        'asset_url'   => $asset_url,
    );

    open my $in, $asset->path or $c->halt(500);

    my $content = do { local $/; <$in> };
    close $in;

    write_file $self->assets_dir . "/$asset_key", { binmode => ':raw' }, $content;

    $self->redis->command('rpush', $self->slot_key($slot), $id);
    $self->redis->command('sadd', $self->advertiser_key($advertiser_id), $key);

    $c->render_json($self->get_ad($c, $slot, $id));
};

get '/slots/{slot:[^/]+}/ad' => sub {
    my ($self, $c) = @_;

    my $ad = $self->next_ad($c);
    if ( $ad ) {
        $c->res->header('Content-Length' => 0);
        $c->redirect($c->req->uri_for('/slots/' . $c->args->{slot} . '/ads/' . $ad->{id})->as_string);
    }
    else {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(JSON->new->encode({ error => 'Not Found' }));
        return $c->res;
    }
};

get '/slots/{slot:[^/]+}/ads/{id:[0-9]+}' => sub {
    my ($self, $c) = @_;

    my $ad = $self->get_ad($c, $c->args->{slot}, $c->args->{id});
    if ( $ad ) {
        my $body = JSON->new->encode($ad);
        $c->res->status(200);
        $c->res->header('Content-Length' => length($body));
        $c->res->content_type('application/json');
        $c->res->body($body);
    }
    else {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(JSON->new->encode({ error => 'Not Found' }));
    }
    return $c->res;
};

get '/slots/{slot:[^/]+}/ads/{id:[0-9]+}/asset' => sub {
    my ($self, $c) = @_;

    my $slot = $c->args->{slot};
    my $id   = $c->args->{id};

    my $ad = $self->get_ad($c, $slot, $id);

    if ( $ad ) {
        $c->res->content_type($ad->{type} || 'video/mp4');
        $c->res->header('X-Accel-Redirect' => '/reproxy');
        $c->res->header('X-Reproxy-URL' => $ad->{asset_url});
        return $c->res;
    }
    else {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(JSON->new->encode({ error => 'Not Found' }));
        return $c->res;
    }
};

post '/slots/{slot:[^/]+}/ads/{id:[0-9]+}/count' => sub {
    my ($self, $c) = @_;

    my $slot = $c->args->{slot};
    my $id   = $c->args->{id};

    my $key = $self->ad_key($slot, $id);

    unless ( $self->redis->command('exists', $key) ) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(JSON->new->encode({ error => 'Not Found' }));
        return $c->res;
    }

    $self->redis->command('hincrby', $key, 'impressions', 1);

    $c->res->status(204);
    return $c->res;
};

get '/slots/{slot:[^/]+}/ads/{id:[0-9]+}/redirect' => sub {
    my ($self, $c) = @_;

    my $slot = $c->args->{slot};
    my $id   = $c->args->{id};

    my $key = $self->ad_key($slot, $id);
    my $ad = $self->get_ad($c, $slot, $id);

    unless ( $ad ) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body(JSON->new->encode({ error => 'Not Found' }));
        return $c->res;
    }

    $self->redis->command('hincrby', $key, 'clicks', 1);
    $self->redis->command('hincrby', "$key:agent", $c->req->env->{'HTTP_USER_AGENT'} || 'unknown', 1);
    my $user = $self->decode_user_key($c->req->cookies->{isuad});
    $self->redis->command('hincrby', "$key:gender", $user->{gender} || 'unknown', 1);
    my $generation = 'unknown';
    $generation = int($user->{age}/10) if $user->{age};
    $self->redis->command('hincrby', "$key:generation", $generation, 1);

    $c->redirect($ad->{destination});
};

get '/me/report' => sub {
    my ($self, $c) = @_;

    my $advertiser_id = $self->advertiser_id($c);

    unless ( $advertiser_id ) {
        $c->halt(401);
    }

    my $ad_keys = $self->redis->command('smembers', $self->advertiser_key($advertiser_id) );

    my $report = {};
    for my $ad_key ( @$ad_keys ) {
        my ($val, $err) = $self->redis->command('hgetall', $ad_key);
        next if $err;
        my %ad = @$val;
        next unless %ad;
        $ad{impressions} = int($ad{impressions});
        my $clicks = int(delete $ad{clicks});
        $report->{$ad{id}} = { ad => \%ad, clicks => $clicks, impressions => $ad{'impressions'} };
    }

    $c->render_json($report);
};

get '/me/final_report' => sub {
    my ($self, $c) = @_;

    my $advertiser_id = $self->advertiser_id($c);

    unless ( $advertiser_id ) {
        $c->halt(401);
    }

    my $reports = {};
    my $ad_keys = $self->redis->command('smembers', $self->advertiser_key($advertiser_id) );
    for my $ad_key ( @$ad_keys ) {
        my ($val, $err) = $self->redis->command('hgetall', $ad_key);
        next if $err;
        my %ad = @$val;
        next unless %ad;
        $ad{impressions} = int($ad{impressions});
        my $clicks = int(delete $ad{clicks});
        $reports->{$ad{id}} = { ad => \%ad, clicks => $clicks, impressions => int($ad{'impressions'}) };
        $reports->{$ad{id}}->{breakdown} = {
            gender => $self->value2int($self->redis->command('hgetall', "$ad_key:gender")),
            agents => $self->value2int($self->redis->command('hgetall', "$ad_key:agent")),
            generations => $self->value2int($self->redis->command('hgetall', "$ad_key:generation")),
        };
    }

    $c->render_json($reports);
};

post '/initialize' => sub {
    my ($self, $c) = @_;

    my @keys = $self->redis->command('keys', 'isu4:*');

    for my $key ( @keys ) {
        $self->redis->command('del', $key);
    }

    for my $file ( glob($self->log_dir . '/*') ) {
        unlink $file;
    }

    for my $file ( glob($self->assets_dir . '/*') ) {
        unlink $file;
    }

    my $self_host = hostname;
    for my $host (grep { $self_host ne $_ } keys %{$config->{map_host2ip}}) {
        my $url = 'http://' . $config->{map_host2ip}{$host} . '/initialize';
        HTTP::Tiny->new->get($host);
    }

    $c->res->content_type('text/plain');
    $c->res->body('OK');
    return $c->res;
};

1;
