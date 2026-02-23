#!/usr/local/bin/perl
# edit_user.cgi — Add or edit a remote mail user
# Supports two modes:
#   ?dom=X              — Create new user
#   ?dom=X&user=Y       — Edit existing user (loads data from email1)
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
my $server = $server_id ? &get_remote_mail_server($server_id) : undef;
$server || &error($text{'setup_enoserver'});

my $editing = $in{'user'} ? 1 : 0;
my $user_data;

if ($editing) {
	$user_data = &get_remote_mail_user($d, $server_id, $in{'user'});
	$user_data || &error($text{'user_enotfound'});
	}

my $title = $editing ? $text{'user_edit_title'} : $text{'domain_add_user'};
&ui_print_header(&virtual_server::domain_in($d), $title, "");

print &ui_form_start("save_domain.cgi", "post");
print &ui_hidden("dom", $d->{'dom'});

if ($editing) {
	print &ui_hidden("action", "save_user");
	print &ui_hidden("old_user", $in{'user'});
	}
else {
	print &ui_hidden("action", "create_user");
	}

print &ui_table_start($text{'user_header'}, undef, 2);

# Email domain (display only)
print &ui_table_row($text{'user_email'},
	"\@".$d->{'dom'});

# Username
if ($editing) {
	print &ui_table_row($text{'user_username'},
		&ui_textbox("username", $in{'user'}, 20));
	}
else {
	print &ui_table_row($text{'user_username'},
		&ui_textbox("username", '', 20));
	}

# Password
print &ui_table_row($text{'user_password'},
	&ui_textbox("password", '', 20).
	" <i>".$text{'user_password_hint'}."</i>");

# Real name
my $real = $editing && $user_data ? ($user_data->{'real_name'} || '') : '';
print &ui_table_row($text{'user_real'},
	&ui_textbox("real", $real, 30));

print &ui_table_end();

# Advanced settings (only when editing)
if ($editing) {
	print &ui_table_start($text{'user_advanced'}, undef, 2);

	# Forwarding
	my $fwd = $user_data->{'forward_to'} || '';
	print &ui_table_row($text{'user_forward'},
		&ui_textbox("forward", $fwd, 40).
		" <i>".$text{'user_forward_hint'}."</i>");

	# Local delivery (keep copy locally when forwarding)
	my $local = ($user_data->{'local_delivery'} || '') eq 'Yes' ? 1 : 0;
	print &ui_table_row($text{'user_local'},
		&ui_yesno_radio("local", $local));

	# Auto-reply
	my $autoreply = $user_data->{'auto_reply'} || '';
	my $has_autoreply = ($autoreply ne '' && $autoreply ne 'No') ? 1 : 0;
	print &ui_table_row($text{'user_autoreply_enabled'},
		&ui_yesno_radio("autoreply_on", $has_autoreply));
	my $autoreply_msg = $has_autoreply ? $autoreply : '';
	print &ui_table_row($text{'user_autoreply_msg'},
		"<textarea name='autoreply_msg' rows='3' cols='50'>".
		&html_escape($autoreply_msg)."</textarea>");

	# Spam filtering
	my $spam = ($user_data->{'check_spam'} || '') eq 'Yes' ? 1 : 0;
	print &ui_table_row($text{'user_spam'},
		&ui_yesno_radio("check_spam", $spam));

	# Account enabled/disabled
	my $enabled = ($user_data->{'enabled'} || 'Yes') eq 'Yes' ? 1 : 0;
	print &ui_table_row($text{'user_enabled'},
		&ui_yesno_radio("enabled", $enabled));

	# Recovery email
	my $recovery = $user_data->{'recovery_email'} || '';
	print &ui_table_row($text{'user_recovery'},
		&ui_textbox("recovery", $recovery, 30));

	# Send update email checkbox
	print &ui_table_row($text{'user_send_update'},
		"<input type='checkbox' name='send_update' value='1'> ".
		$text{'user_send_update_desc'});

	print &ui_table_end();
	}

# Submit buttons
my @buttons = ( [ undef, $editing ? $text{'user_save'} : $text{'domain_add_user'} ] );
if ($editing) {
	push(@buttons, [ 'delete', $text{'user_delete'} ]);
	}
print &ui_form_end(\@buttons);

&ui_print_footer("edit_domain.cgi?dom=$in{'dom'}", $text{'domain_title'},
                 &virtual_server::domain_footer_link($d));
