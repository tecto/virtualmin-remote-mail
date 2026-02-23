#!/usr/local/bin/perl
# save_domain.cgi — Handle per-domain mail actions (domain overrides, SSL,
# user create/edit/delete).
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
elsif ($in{'action'} eq 'create_user') {
	my $server = $server_id ? &get_remote_mail_server($server_id) : undef;
	$server || &error($text{'setup_enoserver'});

	my $username = $in{'username'};
	$username =~ s/^\s+|\s+$//g if defined($username);
	my $verr = &validate_mail_username($username);
	&error($verr) if ($verr);

	my $password = $in{'password'};
	&error($text{'user_epassword'}) if (!$password || $password !~ /\S/);

	my %opts;
	my $real = $in{'real'};
	$real =~ s/^\s+|\s+$//g if defined($real);
	$opts{'real'} = $real if ($real);

	&ui_print_unbuffered_header(&virtual_server::domain_in($d),
	                            $text{'domain_title'}, "");

	&$virtual_server::first_print(&text('user_creating', "${username}\@$in{'dom'}"));
	my $err = &create_remote_mail_user($d, $server_id, $username, $password, \%opts);
	if ($err) {
		&$virtual_server::second_print("<font color=red>$err</font>");
		}
	else {
		&$virtual_server::second_print($virtual_server::text{'setup_done'});
		}

	&webmin_log("user_create", undef, "${username}\@$in{'dom'}");
	&ui_print_footer("/virtual-server/list_users.cgi?dom=".$d->{'id'},
	                 $text{'edit_users'} || "Edit Users");
	}
elsif ($in{'action'} eq 'save_user') {
	my $server = $server_id ? &get_remote_mail_server($server_id) : undef;
	$server || &error($text{'setup_enoserver'});

	my $old_user = $in{'old_user'};
	&error($text{'user_eusername'}) if (!$old_user || $old_user !~ /\S/);

	# Handle delete button
	if ($in{'delete'}) {
		&ui_print_unbuffered_header(&virtual_server::domain_in($d),
		                            $text{'domain_title'}, "");

		&$virtual_server::first_print(&text('user_deleting', "${old_user}\@$in{'dom'}"));
		my $err = &delete_remote_mail_user($d, $server_id, $old_user);
		if ($err) {
			&$virtual_server::second_print("<font color=red>$err</font>");
			}
		else {
			&$virtual_server::second_print($virtual_server::text{'setup_done'});
			}

		&webmin_log("user_delete", undef, "${old_user}\@$in{'dom'}");
		&ui_print_footer("/virtual-server/list_users.cgi?dom=".$d->{'id'},
		                 $text{'edit_users'} || "Edit Users");
		}
	else {
		# Build changes hash from form inputs
		my %changes;

		# Username rename
		my $new_user = $in{'username'};
		$new_user =~ s/^\s+|\s+$//g if defined($new_user);
		if ($new_user && $new_user ne $old_user) {
			my $verr = &validate_mail_username($new_user);
			&error($verr) if ($verr);
			$changes{'newuser'} = $new_user;
			}

		# Password
		my $password = $in{'password'};
		if ($password && $password =~ /\S/) {
			$changes{'pass'} = $password;
			}

		# Real name
		my $real = $in{'real'};
		$real =~ s/^\s+|\s+$//g if defined($real);
		$changes{'real'} = $real if (defined $real);

		# Forwarding
		my $forward = $in{'forward'};
		$forward =~ s/^\s+|\s+$//g if defined($forward);
		if (defined($forward) && $forward ne '') {
			$changes{'add_forward'} = $forward;
			}

		# Local delivery
		if (defined $in{'local'}) {
			if ($in{'local'}) {
				$changes{'local'} = 1;
				}
			else {
				$changes{'no_local'} = 1;
				}
			}

		# Auto-reply
		if (defined $in{'autoreply_on'}) {
			if ($in{'autoreply_on'}) {
				my $msg = $in{'autoreply_msg'} || '';
				$changes{'autoreply'} = $msg if ($msg ne '');
				}
			else {
				$changes{'no_autoreply'} = 1;
				}
			}

		# Spam filtering
		if (defined $in{'check_spam'}) {
			if ($in{'check_spam'}) {
				$changes{'check_spam'} = 1;
				}
			else {
				$changes{'no_check_spam'} = 1;
				}
			}

		# Enable/disable
		if (defined $in{'enabled'}) {
			if ($in{'enabled'}) {
				$changes{'enable'} = 1;
				}
			else {
				$changes{'disable'} = 1;
				}
			}

		# Recovery email
		my $recovery = $in{'recovery'};
		$recovery =~ s/^\s+|\s+$//g if defined($recovery);
		if (defined($recovery) && $recovery ne '') {
			$changes{'recovery'} = $recovery;
			}
		elsif (defined($recovery) && $recovery eq '') {
			$changes{'no_recovery'} = 1;
			}

		# Send update email
		if ($in{'send_update'}) {
			$changes{'send_update_email'} = 1;
			}

		&ui_print_unbuffered_header(&virtual_server::domain_in($d),
		                            $text{'domain_title'}, "");

		my $display_user = $changes{'newuser'} || $old_user;
		&$virtual_server::first_print(&text('user_modifying', "${old_user}\@$in{'dom'}"));
		my $err = &modify_remote_mail_user($d, $server_id, $old_user, \%changes);
		if ($err) {
			&$virtual_server::second_print("<font color=red>$err</font>");
			}
		else {
			&$virtual_server::second_print($virtual_server::text{'setup_done'});
			}

		&webmin_log("user_modify", undef, "${old_user}\@$in{'dom'}");
		&ui_print_footer("/virtual-server/list_users.cgi?dom=".$d->{'id'},
		                 $text{'edit_users'} || "Edit Users");
		}
	}
elsif ($in{'action'} eq 'delete_user') {
	my $server = $server_id ? &get_remote_mail_server($server_id) : undef;
	$server || &error($text{'setup_enoserver'});

	my $username = $in{'username'};
	$username =~ s/^\s+|\s+$//g if defined($username);
	&error($text{'user_eusername'}) if (!$username || $username !~ /\S/);

	&ui_print_unbuffered_header(&virtual_server::domain_in($d),
	                            $text{'domain_title'}, "");

	&$virtual_server::first_print(&text('user_deleting', "${username}\@$in{'dom'}"));
	my $err = &delete_remote_mail_user($d, $server_id, $username);
	if ($err) {
		&$virtual_server::second_print("<font color=red>$err</font>");
		}
	else {
		&$virtual_server::second_print($virtual_server::text{'setup_done'});
		}

	&webmin_log("user_delete", undef, "${username}\@$in{'dom'}");
	&ui_print_footer("/virtual-server/list_users.cgi?dom=".$d->{'id'},
	                 $text{'edit_users'} || "Edit Users");
	}
else {
	&redirect("edit_domain.cgi?dom=$in{'dom'}");
	}
