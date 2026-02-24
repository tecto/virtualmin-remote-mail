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

	my $password = $in{'mailpass'};
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

		# Apply email settings if non-default values were selected
		my %changes;

		# Local delivery: default is checked (tome=1); unchecked means no_local
		if (!$in{'tome'}) {
			$changes{'no_local'} = 1;
			}

		# Forwarding: default is unchecked; if checked, add forwards
		if ($in{'forward'}) {
			my $fwd_text = $in{'forwardto'} || '';
			my @new_fwd = split(/[\r\n]+/, $fwd_text);
			s/^\s+|\s+$//g for @new_fwd;
			@new_fwd = grep { $_ ne '' } @new_fwd;
			$changes{'add_forward'} = \@new_fwd if (@new_fwd);
			}

		# Auto-reply: default is unchecked; if checked, set autoreply
		if ($in{'auto'}) {
			my $msg = $in{'autotext'} || '';
			$msg =~ s/\r//g;
			$changes{'autoreply'} = $msg if ($msg ne '');
			}

		# Spam check: default is nospam=0 (Yes, check spam);
		# nospam=1 means user chose No
		if (defined($in{'nospam'}) && $in{'nospam'}) {
			$changes{'no_check_spam'} = 1;
			}

		if (%changes) {
			&$virtual_server::first_print(
				&text('user_modifying', "${username}\@$in{'dom'}"));
			my $merr = &modify_remote_mail_user(
				$d, $server_id, $username, \%changes);
			if ($merr) {
				&$virtual_server::second_print(
					"<font color=red>$merr</font>");
				}
			else {
				&$virtual_server::second_print(
					$virtual_server::text{'setup_done'});
				}
			}
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

		# Fetch current user data for diffing forwarding addresses
		my $user_data = &get_remote_mail_user($d, $server_id, $old_user);

		# Password (radio: 1=leave unchanged, 0=set to)
		if (!$in{'pass_mode'} && $in{'mailpass'} =~ /\S/) {
			$changes{'pass'} = $in{'mailpass'};
			}

		# Enable/disable (checkbox on password row)
		if ($in{'disable'}) {
			$changes{'disable'} = 1;
			}
		else {
			$changes{'enable'} = 1;
			}

		# Recovery email (opt_textbox: None set vs Offsite address)
		if ($in{'recovery_def'}) {
			$changes{'no_recovery'} = 1;
			}
		else {
			my $recovery = $in{'recovery'} || '';
			$recovery =~ s/^\s+|\s+$//g;
			$changes{'recovery'} = $recovery if ($recovery ne '');
			}

		# Real name
		my $real = $in{'real'};
		$real =~ s/^\s+|\s+$//g if defined($real);
		$changes{'real'} = $real if (defined $real);

		# Local delivery (tome checkbox)
		if ($in{'tome'}) {
			$changes{'local'} = 1;
			}
		else {
			$changes{'no_local'} = 1;
			}

		# Forwarding (checkbox + textarea, diff with current)
		my @old_fwd;
		if ($user_data) {
			my $fwd_raw = $user_data->{'forward_to'} || '';
			@old_fwd = split(/[,\s]+/, $fwd_raw);
			@old_fwd = grep { $_ ne '' } @old_fwd;
			}
		my @new_fwd;
		if ($in{'forward'}) {
			my $fwd_text = $in{'forwardto'} || '';
			&error($text{'user_eforward'})
				if ($fwd_text !~ /\S/);
			@new_fwd = split(/[\r\n]+/, $fwd_text);
			s/^\s+|\s+$//g for @new_fwd;
			@new_fwd = grep { $_ ne '' } @new_fwd;
			}
		my %old_set = map { $_ => 1 } @old_fwd;
		my %new_set = map { $_ => 1 } @new_fwd;
		my @to_add = grep { !$old_set{$_} } @new_fwd;
		my @to_del = grep { !$new_set{$_} } @old_fwd;
		$changes{'add_forward'} = \@to_add if (@to_add);
		$changes{'del_forward'} = \@to_del if (@to_del);

		# Auto-reply (checkbox + textarea)
		if ($in{'auto'}) {
			my $msg = $in{'autotext'} || '';
			$msg =~ s/\r//g;
			$changes{'autoreply'} = $msg if ($msg ne '');
			}
		else {
			$changes{'no_autoreply'} = 1;
			}

		# Spam filtering (radio: 0=Yes check, 1=No don't check)
		if (defined $in{'nospam'}) {
			if ($in{'nospam'}) {
				$changes{'no_check_spam'} = 1;
				}
			else {
				$changes{'check_spam'} = 1;
				}
			}

		# Send updated account email
		if (defined($in{'remail_def'}) && !$in{'remail_def'}) {
			$changes{'send_update_email'} = 1;
			}

		&ui_print_unbuffered_header(&virtual_server::domain_in($d),
		                            $text{'domain_title'}, "");

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
