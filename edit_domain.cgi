#!/usr/local/bin/perl
# edit_domain.cgi — Per-domain remote mail configuration
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
my $state = &get_domain_state($d->{'dom'});

&ui_print_header(&virtual_server::domain_in($d), $text{'domain_title'}, "");

print &ui_table_start($text{'domain_header'}, undef, 2);

# Mail server
print &ui_table_row($text{'domain_server'},
	$server ? &html_escape($server->{'desc'} || $server->{'host'})
	        : "<i>$text{'domain_not_configured'}</i>");

# Status for each component
my @components = (
	['domain_created',     $text{'domain_domain'}],
	['dns_configured',     $text{'domain_dns'}],
	['dkim_configured',    $text{'domain_dkim'}],
	['ssl_synced',         $text{'domain_ssl'}],
);

foreach my $c (@components) {
	my ($key, $label) = @$c;
	my $status = $state->{$key}
		? "<font color=green>$text{'domain_configured'}</font>"
		: "<font color=grey>$text{'domain_not_configured'}</font>";
	print &ui_table_row($label, $status);
	}

# Last SSL sync time
if ($d->{'remote_mail_ssl_synced'}) {
	print &ui_table_row($text{'domain_last_ssl'},
		scalar localtime($d->{'remote_mail_ssl_synced'}));
	}

print &ui_table_end();

# Remote mail features (fetched live from email1)
if ($server_id && $state->{'domain_created'}) {
	my $rdom = &get_remote_domain_info($d, $server_id);
	if ($rdom) {
		print &ui_table_start($text{'domain_remote_features'}, undef, 2);

		my $features = $rdom->{'features'} || '';
		my %feat = map { $_ => 1 } split(/\s+/, $features);

		my @feat_rows = (
			['mail',  $text{'domain_feat_mail'}],
			['spam',  $text{'domain_feat_spam'}],
			['virus', $text{'domain_feat_virus'}],
		);
		foreach my $f (@feat_rows) {
			my ($key, $label) = @$f;
			my $status = $feat{$key}
				? "<font color=green>$text{'domain_feat_enabled'}</font>"
				: "<font color=grey>$text{'domain_feat_disabled'}</font>";
			print &ui_table_row($label, $status);
			}

		# Spam/virus delivery settings
		if ($feat{'spam'} && $rdom->{'spam_delivery'}) {
			my $spam_desc = $rdom->{'spam_delivery'};
			# Translate Virtualmin's confusing "Mail file" wording
			# "Mail file under home .maildir/.Junk/" → Maildir folder
			if ($spam_desc =~ /\.maildir\/\.(\S+)/) {
				$spam_desc = "Maildir folder ~/$1";
				}
			elsif ($spam_desc =~ /Mail file.*\/(\S+)/) {
				$spam_desc = "Mail folder ~/$1";
				}
			print &ui_table_row($text{'domain_feat_spam_delivery'},
				&html_escape($spam_desc));
			}
		if ($feat{'virus'} && $rdom->{'virus_delivery'}) {
			print &ui_table_row($text{'domain_feat_virus_delivery'},
				&html_escape($rdom->{'virus_delivery'}));
			}

		print &ui_table_end();
		}
	}

# Mail routing overrides
if ($server_id && $server) {
	print &ui_form_start("save_domain.cgi", "post");
	print &ui_hidden("dom", $d->{'dom'});
	print &ui_hidden("action", "save_overrides");
	print &ui_table_start($text{'domain_overrides'}, undef, 2);

	my @ovr_fields = (
		[ 'spam_gateway',      $text{'domain_ovr_spam_gateway'} ],
		[ 'spam_gateway_host', $text{'domain_ovr_spam_gateway_host'} ],
		[ 'outgoing_relay',    $text{'domain_ovr_outgoing_relay'} ],
		[ 'outgoing_relay_port', $text{'domain_ovr_outgoing_relay_port'} ],
	);
	foreach my $f (@ovr_fields) {
		my ($key, $label) = @$f;
		my $dk = "remote_mail_${key}";
		my $val = $d->{$dk} || '';
		my $server_default = $server->{$key} || '';
		print &ui_table_row($label,
			&ui_textbox("ovr_${key}", $val, 30).
			($server_default ne '' ? " <i>($text{'feat_ovr_default'}: ".&html_escape($server_default).")</i>" : ''));
		}

	print &ui_table_end();
	print &ui_form_end([ [ undef, $text{'domain_save_overrides'} ] ]);
	}

# Mail users section
if ($server_id && $state->{'domain_created'}) {
	my @users = &list_remote_mail_users($d, $server_id);
	print &ui_columns_start([ $text{'user_email'}, $text{'user_real'},
	                          $text{'servers_actions'} ]);
	foreach my $user (@users) {
		my $uname = $user->{'user'} || $user->{'_name'};
		my $email = $user->{'_name'};
		my $real = $user->{'real_name'} || '';
		my $edit_link = "edit_user.cgi?dom=".&urlize($d->{'dom'}).
		                "&user=".&urlize($uname);
		print &ui_columns_row([
			&ui_link($edit_link, &html_escape($email)),
			&html_escape($real),
			&ui_link($edit_link, $text{'servers_edit'}),
			]);
		}
	if (!@users) {
		print &ui_columns_row([ "<i>$text{'domain_no_users'}</i>", "", "" ]);
		}
	print &ui_columns_end();

	# Add user link
	print &ui_link("edit_user.cgi?dom=".&urlize($d->{'dom'}),
		$text{'domain_add_user'});
	print "<br>\n";
	}

# SSL sync button
if ($server_id && $state->{'ssl_synced'}) {
	print &ui_form_start("save_domain.cgi", "post");
	print &ui_hidden("dom", $d->{'dom'});
	print &ui_hidden("action", "sync_ssl");
	print &ui_form_end([ [ undef, $text{'domain_sync_ssl'} ] ]);
	}

&ui_print_footer(&virtual_server::domain_in($d),
                 $text{'index_return'});
