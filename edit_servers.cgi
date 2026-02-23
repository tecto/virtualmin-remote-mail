#!/usr/local/bin/perl
# edit_servers.cgi — Add/edit a remote mail server, or test connectivity
use strict;
use warnings;
our (%text, %in, %config);
our $module_name;

require 'virtualmin-remote-mail-lib.pl';
&ReadParse();

my $id = $in{'id'};
my $server;
my $is_new = !$id;

if ($id) {
	$server = &get_remote_mail_server($id);
	$server || &error($text{'save_err'});
	}

# Handle test mode
if ($in{'test'} && $id) {
	&ui_print_unbuffered_header(undef, $text{'test_title'}, "");

	&$virtual_server::first_print($text{'test_rpc'});
	my $err = &test_remote_mail_server($id);
	if ($err) {
		&$virtual_server::second_print(
			"<font color=red>$err</font>");
		}
	else {
		&$virtual_server::second_print($text{'test_ok'});
		}

	&ui_print_footer("edit.cgi", $text{'index_return'});
	return;
	}

# Show form
my $title = $is_new ? $text{'server_title_add'} : $text{'server_title_edit'};
&ui_print_header(undef, $title, "");

print &ui_form_start("save_server.cgi", "post");
print &ui_hidden("id", $id || "") if ($id);
print &ui_hidden("new", 1) if ($is_new);
print &ui_table_start($text{'server_header'}, undef, 2);

# Host
print &ui_table_row($text{'server_host'},
	&ui_textbox("host", $server->{'host'}, 40));

# Description
print &ui_table_row($text{'server_desc'},
	&ui_textbox("desc", $server->{'desc'}, 40));

print &ui_table_row("<b>Webmin RPC Settings</b>", "");

# Webmin RPC host
print &ui_table_row($text{'server_webmin_host'},
	&ui_textbox("webmin_host", $server->{'webmin_host'} || $server->{'host'}, 40));

# Webmin port
print &ui_table_row($text{'server_webmin_port'},
	&ui_textbox("webmin_port", $server->{'webmin_port'} || 10000, 6));

# Webmin SSL
print &ui_table_row($text{'server_webmin_ssl'},
	&ui_yesno_radio("webmin_ssl",
		defined($server->{'webmin_ssl'}) ? $server->{'webmin_ssl'} : 1));

# Webmin user
print &ui_table_row($text{'server_webmin_user'},
	&ui_textbox("webmin_user", $server->{'webmin_user'} || 'root', 20));

# Webmin password
print &ui_table_row($text{'server_webmin_pass'},
	&ui_password("webmin_pass", '', 20) .
	($server->{'webmin_pass'} ? " <i>(set)</i>" : ""));

print &ui_table_row("<b>$text{'server_ssh_header'}</b>", "");
print &ui_table_row("", "<i>$text{'server_ssh_note'}</i>");

# SSH host (deprecated — kept for reference)
print &ui_table_row($text{'server_ssh_host'},
	&ui_textbox("ssh_host", $server->{'ssh_host'} || '', 40));

# SSH user (deprecated)
print &ui_table_row($text{'server_ssh_user'},
	&ui_textbox("ssh_user", $server->{'ssh_user'} || '', 20));

# SSH key (deprecated)
print &ui_table_row($text{'server_ssh_key'},
	&ui_textbox("ssh_key", $server->{'ssh_key'} || '', 50));

print &ui_table_row("<b>Mail Routing</b>", "");

# Spam gateway IP
print &ui_table_row($text{'server_spam_gateway'},
	&ui_textbox("spam_gateway", $server->{'spam_gateway'}, 20));

# Spam gateway host prefix
print &ui_table_row($text{'server_spam_gateway_host'},
	&ui_textbox("spam_gateway_host", $server->{'spam_gateway_host'} || 'mg', 10));

# Outgoing relay
print &ui_table_row($text{'server_outgoing_relay'},
	&ui_textbox("outgoing_relay", $server->{'outgoing_relay'}, 40));

# Outgoing relay port
print &ui_table_row($text{'server_outgoing_relay_port'},
	&ui_textbox("outgoing_relay_port", $server->{'outgoing_relay_port'} || 25, 6));

print &ui_table_row("<b>Mail Settings</b>", "");

# DKIM selector
print &ui_table_row($text{'server_dkim_selector'},
	&ui_textbox("dkim_selector", $server->{'dkim_selector'} || '202307', 20));

# Maildir format
print &ui_table_row($text{'server_maildir_format'},
	&ui_textbox("maildir_format", $server->{'maildir_format'} || '.maildir', 20));

# Default server
print &ui_table_row($text{'server_default'},
	&ui_yesno_radio("default", $server->{'default'} || 0));

print &ui_table_end();
print &ui_form_end([ [ undef, $text{'save'} || "Save" ] ]);

&ui_print_footer("edit.cgi", $text{'index_return'});
