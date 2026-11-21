#!/usr/bin/perl
# A stand-in OpenAI-compatible endpoint for device rounds (#67), served by a
# vphone host, which has perl and no Python. Sign in to it in Model Providers
# as an OpenAI-compatible API with any key and the base URL
# http://<address>:<port>/v1; Fetch Models lists one model, `stand-in`.
#
# Each chat request is answered as the mode file says when it arrives, so a
# round switches modes without restarting it:
#
#   ok          a short reply (the default, and what a model's check needs)
#   quota       429 `quota_exceeded`, as GitHub Copilot's spent allowance
#   quota-late  the same, 5 s later
#   ratelimit   429 `rate_limited` with Retry-After: 30, a burst
#   silent      takes the request and never answers
#   stall       starts a reply, "Hello ", and goes silent
#
# Usage: perl stand-in-endpoint.pl address [port] [mode file], the address
# the host has on its guests' network.
# Each request is logged on one line, with the mode it was answered in.
use strict;
use warnings;
use IO::Socket::INET;
use POSIX qw(strftime);

my $address = shift
    // die "usage: perl stand-in-endpoint.pl address [port] [mode file]\n";
my $port = shift // 8099;
my $modes = shift // '/tmp/apelin-stand-in-mode';

$| = 1;
$SIG{CHLD} = 'IGNORE';
my $server = IO::Socket::INET->new(
    LocalAddr => $address,
    LocalPort => $port,
    Listen => 16,
    ReuseAddr => 1,
) or die "cannot listen on $address:$port: $!\n";
print "listening on http://$address:$port/v1, mode from $modes\n";

while (my $client = $server->accept) {
    my $pid = fork;
    if (!defined $pid || $pid) {
        close $client;
        next;
    }
    close $server;
    serve($client);
    exit 0;
}

sub mode {
    open my $file, '<', $modes or return 'ok';
    my $mode = <$file> // 'ok';
    $mode =~ s/\s+//g;
    return $mode eq '' ? 'ok' : $mode;
}

sub serve {
    my ($client) = @_;
    binmode $client;
    $client->autoflush(1);
    my $request = '';
    while (index($request, "\r\n\r\n") < 0) {
        my $read = sysread($client, my $chunk, 65536);
        return unless $read;
        $request .= $chunk;
    }
    my ($line) = $request =~ /^([^\r\n]*)/;
    my ($length) = $request =~ /\r\ncontent-length:\s*(\d+)/i;
    my $body = substr($request, index($request, "\r\n\r\n") + 4);
    while (length($body) < ($length // 0)) {
        my $read = sysread($client, my $chunk, 65536);
        last unless $read;
        $body .= $chunk;
    }
    my $mode = $line =~ m{^GET } ? 'models' : mode();
    print strftime('%H:%M:%S', localtime), " $line ($mode)\n";

    my $quota = '{"error":{"message":"You have exceeded your premium request allowance.","code":"quota_exceeded"}}';
    if ($mode eq 'models') {
        answer($client, 200, 'application/json', '{"object":"list","data":[{"id":"stand-in","object":"model"}]}');
    } elsif ($mode eq 'quota') {
        answer($client, 429, 'application/json', $quota);
    } elsif ($mode eq 'quota-late') {
        sleep 5;
        answer($client, 429, 'application/json', $quota);
    } elsif ($mode eq 'ratelimit') {
        answer($client, 429, 'application/json',
            '{"error":{"message":"Sorry, you have been rate-limited. Please wait a moment before trying again.","code":"rate_limited"}}',
            "Retry-After: 30\r\n");
    } elsif ($mode eq 'silent') {
        sleep 3600;
    } elsif ($mode eq 'stall') {
        print $client "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
            qq(data: {"id":"x","choices":[{"index":0,"delta":{"content":"Hello "}}]}\n\n);
        sleep 3600;
    } else {
        answer($client, 200, 'text/event-stream',
            qq(data: {"id":"x","choices":[{"index":0,"delta":{"content":"Answered by the stand-in."},"finish_reason":"stop"}]}\n\n)
            . "data: [DONE]\n\n");
    }
}

sub answer {
    my ($client, $status, $type, $body, $headers) = @_;
    $headers //= '';
    print $client "HTTP/1.1 $status Stand-In\r\nContent-Type: $type\r\n$headers"
        . 'Content-Length: ' . length($body) . "\r\nConnection: close\r\n\r\n$body";
    close $client;
}
