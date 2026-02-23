#!/usr/local/bin/perl
# save_server.cgi — Save or delete a remote mail server configuration
use strict;
use warnings;
our (%text, %in, %config);
our $module_name;

require 'virtualmin-remote-mail-lib.pl';
&ReadParse();
&error_setup($text{'save_err'});

# Determine the server ID
my $id = $in{'id'};
my $is_new = $in{'new'};

# Handle delete
if ($in{'delete'}) {
	$id || &error($text{'delete_err'});
	&delete_remote_mail_server($id);
	&webmin_log("delete", "server", $id);
	&redirect("edit.cgi");
	return;
	}

# Validate required fields
$in{'host'} =~ /\S/ || &error($text{'save_ehost'});
$in{'webmin_host'} =~ /\S/ || &error($text{'save_ewebmin_host'});
$in{'webmin_user'} =~ /\S/ || &error($text{'save_ewebmin_user'});

# Generate ID for new servers
if ($is_new) {
	my @existing = &list_remote_mail_servers();
	# Find next numeric ID
	my $max = 0;
	foreach my $eid (@existing) {
		$max = $eid if ($eid =~ /^\d+$/ && $eid > $max);
		}
	$id = $max + 1;
	}

# Build server config hash
my %server = (
	host                => $in{'host'},
	desc                => $in{'desc'},
	webmin_host         => $in{'webmin_host'},
	webmin_port         => $in{'webmin_port'} || 10000,
	webmin_ssl          => $in{'webmin_ssl'} || 0,
	webmin_user         => $in{'webmin_user'} || 'root',
	ssh_host            => $in{'ssh_host'} || '',
	ssh_user            => $in{'ssh_user'} || '',
	ssh_key             => $in{'ssh_key'} || '',
	spam_gateway        => $in{'spam_gateway'},
	spam_gateway_host   => $in{'spam_gateway_host'} || 'mg',
	outgoing_relay      => $in{'outgoing_relay'},
	outgoing_relay_port => $in{'outgoing_relay_port'} || 25,
	dkim_selector       => $in{'dkim_selector'} || '202307',
	maildir_format      => $in{'maildir_format'} || '.maildir',
	default             => $in{'default'} || 0,
);

# Password: keep existing if not provided; require on new servers
if ($in{'webmin_pass'}) {
	$server{'webmin_pass'} = $in{'webmin_pass'};
	}
elsif (!$is_new) {
	my $existing = &get_remote_mail_server($id);
	$server{'webmin_pass'} = $existing->{'webmin_pass'} if ($existing);
	}
if (!$server{'webmin_pass'}) {
	&error($text{'save_ewebmin_pass'});
	}

# If marking as default, unmark all others
if ($server{'default'}) {
	foreach my $oid (&list_remote_mail_servers()) {
		next if ($oid eq $id);
		my $other = &get_remote_mail_server($oid);
		if ($other->{'default'}) {
			$other->{'default'} = 0;
			&save_remote_mail_server($oid, $other);
			}
		}
	}

&save_remote_mail_server($id, \%server);
&webmin_log("save", "server", $id);
&redirect("edit.cgi");
