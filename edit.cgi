#!/usr/bin/perl
# edit.cgi — Main module page: shows overview and links to server management
use strict;
use warnings;
our (%text, %in, %config);
our $module_name;

require 'virtualmin-remote-mail-lib.pl';
&ReadParse();

&ui_print_header(undef, $text{'index_title'}, "", undef, 1, 1);

# List configured remote mail servers
my @servers = &list_remote_mail_servers();

if (@servers) {
	print &ui_columns_start([ $text{'servers_host'},
	                           $text{'servers_desc'},
	                           $text{'servers_default'},
	                           $text{'servers_actions'} ]);
	foreach my $id (sort @servers) {
		my $s = &get_remote_mail_server($id);
		my $def = $s->{'default'} ? '&#10003;' : '';
		my $actions = &ui_link("edit_servers.cgi?id=$id",
		                       $text{'servers_edit'}) . " | " .
		              &ui_link("edit_servers.cgi?id=$id&test=1",
		                       $text{'servers_test'});
		print &ui_columns_row([
			&html_escape($s->{'host'}),
			&html_escape($s->{'desc'} || ''),
			$def,
			$actions,
			]);
		}
	print &ui_columns_end();
	}
else {
	print "<p>$text{'servers_none'}</p>\n";
	}

print "<p><a href='edit_servers.cgi'>$text{'servers_add'}</a></p>\n";

&ui_print_footer("/", $text{'index_return'});
