#!/usr/bin/perl

#
# ----------------------------------------------------------------------------
# "THE BEER-WARE LICENSE" (Revision 42):
# ramo@goodvikings.com wrote this file. As long as you retain this notice you
# can do whatever you want with this stuff. If we meet some day, and you think
# this stuff is worth it, you can buy me a beer in return. Ramo
# ----------------------------------------------------------------------------
#

use strict;
use warnings;

use Data::Dumper;

use JSON;
use DateTime;

# used for authing to tinder
my $facebookAuthToken;
my $facebookProfileID;
my $tinderAuthToken;

# globals used throughout
my $stateFile;
my $pairs;
my $updates;
my $myID;

my $apiEndpoint = 'api.gotinder.com';

sub readFBCreds {
	my ($args) = @_;
	if (!defined $args->{'filename'}) {
		die "Please specify a file for facebook creds\n";
	}
	open(FILE, $args->{'filename'}) or die "Can't open $args->{'filename'}: $!";
	$facebookAuthToken = <FILE>;
	$facebookProfileID = <FILE>;
	close(FILE);
}

# read in the state JSON file. Contains pairings, unpaired beaus, and unsent messages
sub readState {
	my ($args) = @_;
	if (!defined $args->{'filename'}) {
		die "Please specify a state file\n";
	}

	$stateFile = $args->{'filename'};
	local $/= undef;
	open(FILE, $stateFile) or die "Can't open $stateFile: $!";
	$pairs = JSON->new->decode(<FILE>);
	$tinderAuthToken = $pairs->{'tinderAuthToken'};
	$myID = $pairs->{'myID'};
	close(FILE);
}

# save the state json file
sub saveState {
	$pairs->{'tinderAuthToken'} = $tinderAuthToken;
	$pairs->{'myID'} = $myID;
	open(FILE, '>', $stateFile) or die "Can't open $stateFile: $!";
	print FILE JSON->new->encode($pairs);
	close(FILE);
}

# check if our auth is working
sub checkAuth {
	if (!defined $pairs->{'tinderAuthToken'}) {
		return;
	}
	
	my $curlStr = buildCurlURL({httpVerb => 'GET', path => 'meta', xAuthHeader => 1});
	if (`$curlStr` eq 'Unauthorized') {
		undef $pairs->{'tinderAuthToken'};
	}
}

# build the api url for curl. Takes a hashmap with possible params httpVerb, path, xAuthHeader and postData
sub buildCurlURL {
	my ($args) = @_;
	return 'curl -s -X ' . (defined $args->{'httpVerb'} ? $args->{'httpVerb'} : 'GET') . ' https://' . $apiEndpoint . '/' . (defined $args->{'path'} ? $args->{'path'} : '')
		. ' -H "Content-type: application/json; charset=utf-8" -H "User-agent: Tinder Android Version 4.4.4"'
		. (defined $args->{'xAuthHeader'} ? " -H \"X-Auth-Token: $tinderAuthToken\"" : '')
		. (defined $args->{'postData'} ? " --data '$args->{'postData'}'" : '');
}

# get an authentication token from the tinder API
sub tinderAuth {
	if (defined $pairs->{'tinderAuthToken'}) {
		return;
	}

	my $curlStr = buildCurlURL({httpVerb => 'POST', path => 'auth', postData => JSON->new->encode({facebook_token => $facebookAuthToken, facebook_id => $facebookProfileID, locale => 'en'})});
	my $resp = `$curlStr`;
	$resp = JSON->new->decode($resp);

	if (defined $resp->{'error'}) {
		print STDERR "Failure in Authentication\nHTTP Response Code: $resp->{'code'}\nMessage: $resp->{'error'}\n";
		exit 127;
	}

	$tinderAuthToken = $resp->{'token'};
	$myID = $resp->{'user'}->{'_id'};
}

# get any updates from the tinder api
sub getUpdates {
	my $curlStr = buildCurlURL({httpVerb => 'POST', path => 'updates', xAuthHeader => 1, postData => JSON->new->encode({last_activity_date => ''})});
	my $resp = JSON->new->decode(`$curlStr`);

	if (defined $resp->{'error'}) {
		print STDERR "Failure in fetching updates\nHTTP Response Code: $resp->{'code'}\nMessage: $resp->{'error'}\n";
		exit 127;
	}

	$updates = $resp;

	$pairs->{'last_activity_date'} = DateTime->now(time_zone => 'GMT')->iso8601() . '.000Z';
}

# checks the update list and for any new IDs, adds them to the unpaired IDs list
sub updateUnpaired {
	foreach (@{$updates->{'matches'}}) {
		if (defined $_->{'person'}) {
			# if the person ID is not in any pairs, nor in unmatched IDs:
			if (!defined $pairs->{'pairs'}->{$_->{'person'}->{'_id'}}) {
				if (!defined $pairs->{'unpaired'}->{$_->{'person'}->{'_id'}}) {
					# then add it in as an unmatched ID
					$pairs->{'unpaired'}->{$_->{'person'}->{'_id'}} = $_->{'_id'};
				}
			}
		}
	}
}

# pair up any available beaus
sub pairAvailable {	
	my $single;
	for (keys(%{$pairs->{'unpaired'}})) {
		if (!defined $single) {
			$single = $_;
		} else {
			$pairs->{'pairs'}->{$single} = $_;
			$pairs->{'pairs'}->{$_} = $single;
			$pairs->{'conversationLog'}->{$single} = $_ . $single;
			$pairs->{'conversationLog'}->{$_} = $_ . $single;
			delete $pairs->{'unpaired'}->{$_};
			delete $pairs->{'unpaired'}->{$single};
			undef $single;
		}
	}
}

# get any new messages, prepare them to be forwarded
sub processNewMessages {
	for (@{$updates->{'matches'}}) {
		for (@{$_->{messages}}) {
			if (doesMessageExist({message => $_})) {
				next;
			}

			$_->{'message'} =~ s/'//gms;
			if ($_->{'from'} ne $myID) {
				push @{$pairs->{'messages'}}, {matchID => $_->{'match_id'}, message => $_->{'message'}, from => $_->{'from'}, timestamp => $_->{'timestamp'}, messageID => $_->{'_id'}, sent => 0};
			} else {
				open(FILE, '>>', $pairs->{'conversationLog'}->{$_->{'from'}});
				print FILE $_->{'from'} . ': ' . $_->{'message'} . "\n";
				close(FILE);
			}
		}
	}
}

sub doesMessageExist {
	my ($args) = @_;

	if (defined $pairs->{'messages'}) {
		for (@{$pairs->{'messages'}}) {
			if ($_->{'messageID'} eq $args->{'message'}->{'_id'}) {
				return 1;
			}
		}
	}

	return 0;
}

sub sendMessages {
	if (defined $pairs->{'messages'}) {
		for (sort {$a->{'timestamp'} <=> $b->{'timestamp'}} @{$pairs->{'messages'}}) {
			if ($_->{'sent'} == 0) {
				$_->{'sent'} = sendMessage({message => $_});
			}
		}
	}
}

sub sendMessage {
	my ($args) = @_;
	
	if (!defined $args->{message}) {
		return;
	}

	if (defined $pairs->{'unpaired'}->{$args->{'message'}->{'from'}}) {
		return 0;
	}

	my $curlStr = buildCurlURL({httpVerb => 'POST', xAuthHeader => 1, path => 'user/matches/' . $pairs->{'pairs'}->{$args->{'message'}->{'from'}} . $myID, postData => JSON->new->encode({message => $args->{'message'}->{'message'}})});
	my $resp = JSON->new->decode(`$curlStr`);

	if (defined $resp->{'error'}) {
		if ($resp->{'error'} ne "Match not found") {
			print STDERR "Failure in sending message\nHTTP Response Code: $resp->{'code'}\nMessage: $resp->{'error'}\nWith curl command: $curlStr\n";
			return 0;
		}
	}

	open(FILE, '>>', $pairs->{'conversationLog'}->{$args->{'message'}->{'from'}} . '.txt');
	print FILE $args->{'message'}->{'from'} . ': ' . $args->{'message'}->{'message'} . "\n";
	close(FILE);

	saveState();

	return 1;
}

# like everyone we can
sub likeAllThePeople {
	my $likesRemaining = getLikesRemaining();
	my $suggestions;
	my $count = 0;

	while ($likesRemaining > 0) {
		$suggestions = getSuggestions();

		for (@{$suggestions}) {
			$likesRemaining = likeUser({id => $_});
			$count++;
			if ($likesRemaining > 0) {
				sleep(1);
			} else {
				last;
			}
		}
		$likesRemaining = getLikesRemaining();
	}
	
	if ($count > 0) {
		print "$count people liked\n";
	}
}

# get remaining like count from API
sub getLikesRemaining {
	# get our number of remaining likes
	my $curlStr = buildCurlURL({httpVerb => 'GET', path => 'meta', xAuthHeader => 1});
	my $resp = JSON->new->decode(`$curlStr`);
	
	if (defined $resp->{'error'}) {
		print STDERR "Failure in fetching meta\nHTTP Response Code: $resp->{'code'}\nMessage: $resp->{'error'}\n";
		exit 127;
	}

	return $resp->{'rating'}->{'likes_remaining'};
}

# get list of people to like
sub getSuggestions {
	my $retVal;
	my $curlStr = buildCurlURL({httpVerb => 'GET', path => 'user/recs?locale=en', xAuthHeader => 1});
	my $resp = JSON->new->decode(`$curlStr`);
	
	if (defined $resp->{'error'}) {
		print STDERR "Failure in fetching suggestion list\nHTTP Response Code: $resp->{'code'}\nMessage: $resp->{'error'}\n";
		exit 127;
	}

	for (@{$resp->{'results'}}) {
		push @{$retVal}, $_->{'_id'};
	}
	
	return $retVal;	
}

sub likeUser {
	my ($args) = @_;

	my $curlStr = buildCurlURL({httpVerb => 'GET', path => "like/$args->{'id'}", xAuthHeader => 1});
	my $resp = JSON->new->decode(`$curlStr`);
	
	if (defined $resp->{'error'}) {
		print STDERR "Failure in liking someone\nHTTP Response Code: $resp->{'code'}\nMessage: $resp->{'error'}\n";
		exit 127;
	}

	return $resp->{'likes_remaining'};
}

##### main starts here #####

# read in cred for facebook
readFBCreds({filename => shift});

# read in state file
readState({filename => shift});

# check our token with a sample request
checkAuth();

# Authenticate to the tinder API
tinderAuth();

# fetch updates from tinder
getUpdates();

# get any as yet unpaired beaus
updateUnpaired();

# pair up available unpaired beaus
pairAvailable();

# get any new messages, prepare for forwarding
processNewMessages();

# send messages
sendMessages();

# like everyone
likeAllThePeople();

# save state file
saveState();
