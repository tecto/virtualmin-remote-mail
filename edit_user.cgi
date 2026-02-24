#!/usr/local/bin/perl
# edit_user.cgi — Add or edit a remote mail user
# Layout matches the standard Virtualmin user edit form.
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
my $local_user = $in{'user'} || '';
$local_user =~ s/\@.*$// if ($local_user =~ /\@/);

if ($editing) {
	$user_data = &get_remote_mail_user($d, $server_id, $local_user);
	$user_data || &error($text{'user_enotfound'});
	}

my $title = $editing ? $text{'user_edit_title'} : $text{'domain_add_user'};
&ui_print_header(&virtual_server::domain_in($d), $title, "");

print &ui_form_start("save_domain.cgi", "post");
print &ui_hidden("dom", $d->{'dom'});

if ($editing) {
	print &ui_hidden("action", "save_user");
	print &ui_hidden("old_user", $local_user);
	}
else {
	print &ui_hidden("action", "create_user");
	}

# ---- User details section ----
print &ui_hidden_table_start($text{'user_header'}, "width=100%", 2,
	"table1", 1);

if ($editing) {
	# Login username (display only, full email)
	print &ui_table_row($text{'user_login'},
		"<tt>".&html_escape($local_user."\@".$d->{'dom'})."</tt>");

	# Email address (editable local part + fixed domain)
	print &ui_table_row($text{'user_email'},
		&ui_textbox("username", $local_user, 20).
		"\@".$d->{'dom'});

	# Password: Leave unchanged / Set to .. + disabled checkbox
	my $enabled = ($user_data->{'disabled'} || 'No') eq 'No' ? 1 : 0;
	my $pwfield = &ui_radio("pass_mode", 1,
		[ [ 1, $text{'user_pass_leave'}."<br>" ],
		  [ 0, $text{'user_pass_set'}." ".
		       &ui_password("mailpass", undef, 20, 0, undef,
		                    "data-password") ] ]);
	$pwfield .= "<br>".
		&ui_checkbox("disable", 1, $text{'user_disabled'}, !$enabled);
	print &ui_table_row($text{'user_password'}, $pwfield);

	# Password recovery address
	my $recovery = $user_data->{'recovery_email'} || '';
	print &ui_table_row($text{'user_recovery'},
		&ui_opt_textbox("recovery",
			$recovery ne '' ? $recovery : undef, 40,
			$text{'user_norecovery'},
			$text{'user_gotrecovery'}));

	# Real name
	my $real = $user_data->{'real_name'} || '';
	print &ui_table_row($text{'user_real'},
		&ui_textbox("real", $real, 30));
	}
else {
	# New user: Email address (editable local part + fixed domain)
	print &ui_table_row($text{'user_email'},
		&ui_textbox("username", '', 20).
		"\@".$d->{'dom'});

	# Password (required)
	print &ui_table_row($text{'user_password'},
		&ui_password("mailpass", undef, 20, 0, undef,
		             "data-password"));

	# Real name
	print &ui_table_row($text{'user_real'},
		&ui_textbox("real", '', 30));
	}

print &ui_hidden_table_end("table1");

# ---- Email settings section ----
print &ui_hidden_table_start($text{'user_email_settings'},
	"width=100%", 2, "table2a", $editing ? 0 : 1);

if ($editing) {
	# Deliver to this user normally (local delivery)
	my $has_mail_location = $user_data->{'mail_location'} ? 1 : 0;
	my $local = $has_mail_location ? 1 : 0;
	print &ui_table_row($text{'user_tome'},
		&ui_checkbox("tome", 1, $text{'user_tome_yes'}, $local));

	# Forward to other addresses
	my $fwd_raw = $user_data->{'forward_to'} || '';
	my @fwd_addrs;
	if ($fwd_raw ne '') {
		@fwd_addrs = split(/[,\s]+/, $fwd_raw);
		@fwd_addrs = grep { $_ ne '' } @fwd_addrs;
		}
	my $has_forwards = scalar(@fwd_addrs) ? 1 : 0;
	print &ui_table_row($text{'user_forward'},
		&ui_checkbox("forward", 1, $text{'user_forward_yes'},
			$has_forwards)."<br>\n".
		&ui_textarea("forwardto", join("\n", @fwd_addrs), 3, 40));

	# Send automatic reply
	my $autoreply_raw = $user_data->{'auto_reply'} || '';
	my $has_autoreply = ($autoreply_raw ne '' &&
		$autoreply_raw ne 'No') ? 1 : 0;
	my $autoreply_msg = $has_autoreply ? $autoreply_raw : '';
	print &ui_table_row($text{'user_auto'},
		&ui_checkbox("auto", 1, $text{'user_auto_yes'},
			$has_autoreply)."<br>\n".
		&ui_textarea("autotext", $autoreply_msg, 5, 60));

	# Check email for spam and viruses?
	my $nospam = ($user_data->{'check_spam_and_viruses'} || '') eq 'Yes' ? 0 : 1;
	print &ui_table_row($text{'user_nospam'},
		&ui_radio("nospam", $nospam,
			[ [ 0, $text{'yes'} ],
			  [ 1, $text{'no'} ] ]));

	# Send updated account email to
	print &ui_table_row($text{'user_remail'},
		&ui_radio("remail_def", 1,
			[ [ 1, $text{'user_remail_no'} ],
			  [ 0, $text{'user_remail_yes'} ] ])." ".
		&ui_textbox("remail",
			$local_user."\@".$d->{'dom'}, 40));
	}
else {
	# New user: sensible defaults
	# Deliver to this user normally (local delivery) — checked by default
	print &ui_table_row($text{'user_tome'},
		&ui_checkbox("tome", 1, $text{'user_tome_yes'}, 1));

	# Forward to other addresses — unchecked, empty
	print &ui_table_row($text{'user_forward'},
		&ui_checkbox("forward", 1, $text{'user_forward_yes'},
			0)."<br>\n".
		&ui_textarea("forwardto", '', 3, 40));

	# Send automatic reply — unchecked, empty
	print &ui_table_row($text{'user_auto'},
		&ui_checkbox("auto", 1, $text{'user_auto_yes'},
			0)."<br>\n".
		&ui_textarea("autotext", '', 5, 60));

	# Check email for spam and viruses? — Yes by default
	print &ui_table_row($text{'user_nospam'},
		&ui_radio("nospam", 0,
			[ [ 0, $text{'yes'} ],
			  [ 1, $text{'no'} ] ]));
	}

print &ui_hidden_table_end("table2a");

# Submit buttons
my @buttons = ( [ undef, $editing ? $text{'user_save'}
                                  : $text{'domain_add_user'} ] );
if ($editing) {
	push(@buttons, [ 'delete', $text{'user_delete'} ]);
	}
print &ui_form_end(\@buttons);

&ui_print_footer("edit_domain.cgi?dom=$in{'dom'}", $text{'domain_title'},
                 &virtual_server::domain_footer_link($d));
