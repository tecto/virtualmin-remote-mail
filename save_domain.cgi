#!/usr/bin/perl
# save_domain.cgi — Handle per-domain mail actions (SSL sync, etc.)
use strict;
use warnings;
our (%text, %in, %config);
our $module_name;

require 'virtualmin-remote-mail-lib.pl';
&ReadParse();

&can_edit_domain($in{'dom'}) || &error($text{'edit_ecannot'} || "Access denied");

my $d = &virtual_server::get_domain_by("dom", $in{'dom'});
$d || &error($text{'edit_edomain'} || "Domain not found");

my $server_id = &get_domain_mail_server($d);

if ($in{'action'} eq 'save_overrides') {
	my $server = $server_id ? &get_remote_mail_server($server_id) : undef;
	$server || &error($text{'setup_enoserver'});

	# Validate and collect changes
	my $changed = 0;
	my %old_overrides;
	foreach my $key (qw(spam_gateway spam_gateway_host outgoing_relay outgoing_relay_port)) {
		my $dk = "remote_mail_${key}";
		$old_overrides{$dk} = $d->{$dk} || '';
		my $new_val = $in{"ovr_${key}"};
		$new_val =~ s/^\s+|\s+$//g if defined($new_val);
		$new_val = '' if !defined($new_val);
		my $verr = &validate_mail_override($key, $new_val);
		&error($verr) if ($verr);
		if ($new_val ne $old_overrides{$dk}) {
			$d->{$dk} = $new_val;
			$changed = 1;
			}
		}

	if ($changed) {
		&ui_print_unbuffered_header(&virtual_server::domain_in($d),
		                            $text{'domain_title'}, "");

		# Build a temporary domain hash with OLD overrides for cleanup.
		# $d already has new values; we need the old ones for delete.
		my %old_d = %$d;
		foreach my $dk (keys %old_overrides) {
			$old_d{$dk} = $old_overrides{$dk};
			}

		# Re-provision DNS: delete with old config, create with new
		my $state = &get_domain_state($d->{'dom'});
		if ($state && $state->{'dns_configured'}) {
			&$virtual_server::first_print($text{'setup_dns'});
			my $err = &delete_remote_mail_dns(\%old_d, $server);
			$err = &setup_remote_mail_dns($d, $server) if (!$err);
			if ($err) {
				&$virtual_server::second_print(
					"<font color=red>$err</font>");
				}
			else {
				&$virtual_server::second_print(
					$virtual_server::text{'setup_done'});
				}
			}

		# Re-provision Postfix: delete with old config, create with new
		if ($state && $state->{'postfix_configured'}) {
			&$virtual_server::first_print($text{'setup_postfix'});
			my $err = &delete_remote_postfix(\%old_d, $server_id, $server);
			$err = &setup_remote_postfix($d, $server_id, $server) if (!$err);
			if ($err) {
				&$virtual_server::second_print(
					"<font color=red>$err</font>");
				}
			else {
				&$virtual_server::second_print(
					$virtual_server::text{'setup_done'});
				}
			}

		# Persist domain hash changes
		&virtual_server::save_domain($d) if defined(&virtual_server::save_domain);

		&webmin_log("save_overrides", undef, $d->{'dom'});
		&ui_print_footer("edit_domain.cgi?dom=$in{'dom'}",
		                 $text{'domain_title'});
		}
	else {
		&redirect("edit_domain.cgi?dom=$in{'dom'}");
		}
	}
elsif ($in{'action'} eq 'sync_ssl') {
	&ui_print_unbuffered_header(&virtual_server::domain_in($d),
	                            $text{'domain_title'}, "");

	&$virtual_server::first_print($text{'setup_ssl'});
	my $err = &sync_remote_mail_ssl($d, $server_id);
	if ($err) {
		&$virtual_server::second_print(
			"<font color=red>$err</font>");
		}
	else {
		$d->{'remote_mail_ssl_synced'} = time();
		&virtual_server::save_domain($d) if defined(&virtual_server::save_domain);
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}

	&webmin_log("ssl_sync", undef, $d->{'dom'});
	&ui_print_footer("edit_domain.cgi?dom=$in{'dom'}",
	                 $text{'domain_title'});
	}
else {
	&redirect("edit_domain.cgi?dom=$in{'dom'}");
	}
