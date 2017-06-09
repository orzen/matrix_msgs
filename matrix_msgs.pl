# Copyright (c) 2017 Mattias Hansson, <hansson.mattias@gmail.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

use strict;
use warnings;

use Irssi;
use Irssi::Irc;
use POSIX qw(strftime);

use HTTP::Request::Common;
use JSON::XS;
use LWP::UserAgent();

use vars qw($VERSION %IRSSI);

# Dependencies:
# HTTP::Request::Common
# JSON::XS
# LWP::Protocol::https
# LWP::UserAgent

# Inherit
$VERSION = '1.0';
%IRSSI = (
	author      => 'Mattias Hansson',
	contact     => 'hansson.mattias@gmail.com',
	url         => 'http://github.com/orzen/matrix_msgs',
	name        => 'matrix_msgs',
	description => "Forward private messages/mentions to a matrix account.",
	license     => "MIT",
);

# Globals
my $FORMAT;
my $agent;
my $room_id_filename;
my %settings_str;
my $settings_section;
my $settings_user;
my $settings_node;
my $settings_password;
my $settings_to_user;
my $settings_to_node;
my $settings_away_only;
my $settings_priv_msgs;
my $settings_mentions;
my $settings_room;
my $window;

$FORMAT = $IRSSI{'name'} . '_crap';
$settings_section = 'misc';
$agent = LWP::UserAgent->new;
$room_id_filename = Irssi::get_irssi_dir . '/matrix_room_id_cache';

# Construct settings strings
%settings_str = (
	user      => $IRSSI{'name'} . '_user',
	node      => $IRSSI{'name'} . '_node',
	password  => $IRSSI{'name'} . '_password',
	to_user   => $IRSSI{'name'} . '_to_user',
	to_node   => $IRSSI{'name'} . '_to_node',
	room      => $IRSSI{'name'} . '_room',
	away_only => $IRSSI{'name'} . '_forward_when_away_only',
	priv_msgs => $IRSSI{'name'} . '_send_private_messages',
	mentions  => $IRSSI{'name'} . '_send_mentions',
);

sub irc_log {
	my ($str) = @_;

	$window->printformat(Irssi::MSGLEVEL_CLIENTCRAP, $FORMAT, $str);

	return;
}

sub file_read_line {
	my ($filename) = @_;

	my $row;

	if (open(my $fd, '<:encoding(UTF-8)', $filename)) {
		$row = <$fd>;
		chomp $row;
		close $fd;
	} else {
		irc_log("failed to open file '$filename' for reading: $!");
		return;
	}

	return $row;
}

sub file_write_line {
	my ($line, $filename) = @_;

	if (open(my $fd, '>:encoding(UTF-8)', $filename)) {
		print $fd $line;
		close $fd;
	} else {
		irc_log("failed to open file '$filename' for writing: $!");
	}

	return;
}

sub http_dispatch_json {
	my ($method, $endpoint, %msg) = @_;

	my $decoded_res;
	my $json;
	my $req;
	my $res;

	$req = HTTP::Request->new($method, $endpoint);

	if (defined(\%msg)) {
		$json = encode_json(\%msg);

		$req->header('Content-Type' => 'application/json');
		$req->content($json);
	}

	$res = $agent->request($req);

	if ($res->is_success) {
		$decoded_res = decode_json($res->content);
	} else {
		return $decoded_res;
	}

	return %$decoded_res;
}

sub matrix_login {
	my ($node, $user, $password) = @_;

	my %msg;
	my %res;
	my $url;

	$url = $node . "/_matrix/client/r0/login";

	$msg{'type'} = "m.login.password";
	$msg{'user'} = $user;
	$msg{'password'} = $password;

	# Notice: If you get an issue with requests make sure that
	# LWP::Protocol::https is installed.
	%res = http_dispatch_json('POST', $url, %msg);

	return $res{'access_token'};
}

sub matrix_sync {
	my ($node, $access_token) = @_;

	my %msg;
	my $endpoint;
	my $url;
	my %res;

	$endpoint = "/_matrix/client/r0/sync?access_token=" . $access_token;
	$url = $node . $endpoint;

	%res = http_dispatch_json('GET', $url);

	return %res;
}

sub matrix_create_room {
	my ($node, $access_token, $to_user, $to_node, $room) = @_;

	my $endpoint;
	my %msg;
	my %res;
	my @invite;
	my $url;

	$endpoint = "/_matrix/client/r0/createRoom?access_token=" . $access_token;
	$url = $node . $endpoint;

	@invite = ('@' . $to_user . ':' . $to_node);

	$msg{'invite'} = \@invite;
	$msg{'preset'} = "private_chat";
	$msg{'room_alias_name'} = $room;

	%res = http_dispatch_json('POST', $url, %msg);

	if ($res{'errcode'}) {
		irc_log('failed to create room: ' . $res{'error'});
	} else {
		return $res{'room_id'};
	}

	return;
}

sub matrix_send_msg {
	my ($node, $room_id, $transaction_id, $access_token, $message) = @_;

	my $endpoint;
	my $url;
	my %msg;
	my $json;
	my $req;
	my %res;

	$endpoint = "/_matrix/client/r0/rooms/" .
	            $room_id .
	            "/send/m.room.message/" .
	            $transaction_id .
	            "?access_token=" . $access_token;
	$url = $node . $endpoint;

	$msg{'msgtype'} = "m.text";
	# TODO encode message
	$msg{'body'} = $message;

	%res = http_dispatch_json('PUT', $url, %msg);

	return $res{'event_id'};
}

sub send_message {
	my ($node,
	    $user,
	    $password,
	    $to_user,
	    $to_node,
	    $room,
	    $room_id_filename_,
	    $message) = @_;

	my $access_token;
	my $event_id;
	my $random;
	my $transaction_id;
	my $room_id;
	my $room_id_cached;
	my %sync_res;

	$access_token = matrix_login($node, $user, $password);
	if (not $access_token) {
		irc_log("failed to login");
		return;
	}

	if (-e $room_id_filename_) {
		$room_id_cached = file_read_line($room_id_filename_);
	}

	# Get sync-data to verify membership of the room
	%sync_res = matrix_sync($node, $access_token);
	if (not %sync_res) {
		irc_log("failed to get sync data");
	}

	# Verifying room membership or creating a new room
	if (%sync_res and $sync_res{'rooms'}{'join'}{$room_id_cached}){
		$room_id = $room_id_cached;
	} else {
		$room_id = matrix_create_room($node, $access_token, $to_user, $to_node, $room);
	}

	if ($room_id) {
		# No need to re-write the cached room id
		if (not $room_id_cached) {
			file_write_line($room_id, $room_id_filename_);
		}

		# Creating a transaction ID
		$random = int(rand(1000000));
		$transaction_id = "$random";

		# TODO come up with a good way to generate transaction id
		$event_id = matrix_send_msg($node,
		                            $room_id,
		                            $transaction_id,
		                            $access_token,
		                            $message);

		if ($event_id) {
			irc_log('successfully sent a message to @' .  $user . ':' . $node);
		} else {
			irc_log('failed to send a message to @' . $user . ':' . $node);
		}
	} else {
		irc_log("failed to create room '" . $room . "'");
	}

	return;
}

sub handle_pub_msgs {
	my ($server, $message, $user, $address, $target) = @_;

	my $message_str;

	if ((index($message, $server->{nick}) >= 0) &&
	    $settings_mentions &&
	    (!$settings_away_only || $server->{usermode_away})) {
		$message_str = $user . '@' . $target . ': ' . $message;

		send_message($settings_node,
		             $settings_user,
		             $settings_password,
		             $settings_to_user,
		             $settings_to_node,
		             $settings_room,
		             $room_id_filename,
		             $message_str);
	}

	return;
}

sub handle_priv_msgs {
	my ($server, $message, $user, $address) = @_;

	my $message_str;

	if ($settings_priv_msgs &&
	    (!$settings_away_only || $server->{usermode_away})) {
		$message_str = "$user (private): $message";

		send_message($settings_node,
		             $settings_user,
		             $settings_password,
		             $settings_to_user,
		             $settings_to_node,
		             $settings_room,
		             $room_id_filename,
		             $message_str);
	}

	return;
}

sub load_settings {
	# Read the values of the settings
	$settings_node      = Irssi::settings_get_str($settings_str{'node'});
	$settings_user      = Irssi::settings_get_str($settings_str{'user'});
	$settings_password  = Irssi::settings_get_str($settings_str{'password'});
	$settings_to_user   = Irssi::settings_get_str($settings_str{'to_user'});
	$settings_to_node   = Irssi::settings_get_str($settings_str{'to_node'});
	$settings_room      = Irssi::settings_get_str($settings_str{'room'});
	$settings_away_only = Irssi::settings_get_bool($settings_str{'away_only'});
	$settings_priv_msgs = Irssi::settings_get_bool($settings_str{'priv_msgs'});
	$settings_mentions  = Irssi::settings_get_bool($settings_str{'mentions'});
}

sub init {
	Irssi::theme_register(
		[
			script_loaded => 'Loaded script {hilight $0} v$1',
			$FORMAT => '$0',
		]);

	$window = Irssi::active_win;

	# Add settings to irssi
	Irssi::settings_add_str($settings_section, $settings_str{'user'}, 'guest');
	Irssi::settings_add_str($settings_section, $settings_str{'node'}, 'https://matrix.org');
	Irssi::settings_add_str($settings_section, $settings_str{'password'}, '');
	Irssi::settings_add_str($settings_section, $settings_str{'to_user'}, '');
	Irssi::settings_add_str($settings_section, $settings_str{'to_node'}, 'https://matrix.org');
	Irssi::settings_add_str($settings_section, $settings_str{'room'}, '');
	Irssi::settings_add_bool($settings_section, $settings_str{'away_only'}, 0);
	Irssi::settings_add_bool($settings_section, $settings_str{'priv_msgs'}, 0);
	Irssi::settings_add_bool($settings_section, $settings_str{'mentions'}, 0);

	load_settings();

	# Same callback function for mentions and public messages
	if ($settings_mentions) {
		Irssi::signal_add_last('message public', 'handle_pub_msgs');
	}

	if ($settings_priv_msgs) {
		Irssi::signal_add_last('message private', 'handle_priv_msgs');
	}

	Irssi::signal_add_last('setup changed', \&load_settings);

	Irssi::printformat(Irssi::MSGLEVEL_CLIENTCRAP,
	                   'script_loaded',
	                   $IRSSI{'name'}, $VERSION);
}

init();
