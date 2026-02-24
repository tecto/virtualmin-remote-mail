#!/usr/bin/perl
# mock-webmin.pl
# Stubs for Webmin global functions and variables used by the plugin.
# Load this BEFORE requiring the library under test.

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# --- Global variables that Webmin modules expect ---
our $module_name = 'virtualmin-remote-mail';
our $module_config_directory;
our %config;
our %module_info;
our %text;
our %in;

# Create a temporary config directory for each test run
BEGIN {
    $module_config_directory = tempdir('vrm-test-XXXX', TMPDIR => 1, CLEANUP => 1);
    make_path("$module_config_directory/domains");
}

# Load language strings from the lang/en file
sub load_language {
    my $lang_file = $ENV{'MOCK_LANG_FILE'} ||
                    "$FindBin::Bin/../lang/en";
    if (-r $lang_file) {
        open(my $fh, '<', $lang_file) or return;
        while (<$fh>) {
            chomp;
            next if /^\s*#/ || /^\s*$/;
            if (/^(\S+?)=(.*)$/) {
                $text{$1} = $2;
                }
            }
        close($fh);
        }
}

# --- Webmin core function stubs ---

# File I/O
our %_file_lines_cache;

sub read_file {
    my ($file, $hash) = @_;
    return 0 unless -r $file;
    open(my $fh, '<', $file) or return 0;
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || /^\s*$/;
        if (/^(\S+?)=(.*)$/) {
            $hash->{$1} = $2;
            }
        }
    close($fh);
    return 1;
}

sub write_file {
    my ($file, $hash) = @_;
    open(my $fh, '>', $file) or die "Cannot write $file: $!";
    foreach my $k (sort keys %$hash) {
        print $fh "$k=$hash->{$k}\n";
        }
    close($fh);
}

sub read_file_lines {
    my ($file, $readonly) = @_;
    if (!$_file_lines_cache{$file}) {
        my @lines;
        if (-r $file) {
            open(my $fh, '<', $file) or return \@lines;
            @lines = map { chomp; $_ } <$fh>;
            close($fh);
            }
        $_file_lines_cache{$file} = \@lines;
        }
    return $_file_lines_cache{$file};
}

sub flush_file_lines {
    my ($file) = @_;
    if ($_file_lines_cache{$file}) {
        open(my $fh, '>', $file) or die "Cannot write $file: $!";
        foreach my $line (@{$_file_lines_cache{$file}}) {
            print $fh "$line\n";
            }
        close($fh);
        delete $_file_lines_cache{$file};
        }
}

sub unlink_file {
    my ($file) = @_;
    unlink($file) if (-e $file);
}

# Locking (no-ops for testing)
our %_locked_files;
sub lock_file {
    my ($file) = @_;
    $_locked_files{$file} = 1;
}

sub unlock_file {
    my ($file) = @_;
    delete $_locked_files{$file};
}

# Directory operations
sub make_dir {
    my ($dir, $perms) = @_;
    make_path($dir);
}

# Module config
sub init_config {
    # Load config from temp directory if it exists
    my $cfile = "$module_config_directory/config";
    if (-r $cfile) {
        &read_file($cfile, \%config);
        }
}

sub save_module_config {
    my $cfile = "$module_config_directory/config";
    &write_file($cfile, \%config);
}

sub get_module_acl {
    return ('dom' => '*');
}

# Form handling
sub ReadParse {
    # Parse from QUERY_STRING or stdin for tests
    my %params;
    if ($ENV{'QUERY_STRING'}) {
        foreach my $pair (split(/&/, $ENV{'QUERY_STRING'})) {
            my ($k, $v) = split(/=/, $pair, 2);
            $v = '' if !defined($v);
            $v =~ s/\+/ /g;
            $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $params{$k} = $v;
            }
        }
    %in = %params;
}

# UI functions (return HTML strings)
sub ui_table_row {
    my ($label, $value) = @_;
    return "<tr><td>$label</td><td>$value</td></tr>\n";
}

sub ui_table_start {
    my ($title, $width, $cols) = @_;
    return "<table><tr><th colspan='$cols'>$title</th></tr>\n";
}

sub ui_table_end {
    return "</table>\n";
}

sub ui_form_start {
    my ($action, $method) = @_;
    $method ||= 'post';
    return "<form action='$action' method='$method'>\n";
}

sub ui_form_end {
    my ($buttons) = @_;
    my $html = '';
    if ($buttons) {
        foreach my $b (@$buttons) {
            $html .= "<input type='submit' value='$b->[1]'>\n";
            }
        }
    $html .= "</form>\n";
    return $html;
}

sub ui_hidden {
    my ($name, $value) = @_;
    return "<input type='hidden' name='$name' value='$value'>\n";
}

sub ui_textbox {
    my ($name, $value, $size) = @_;
    return "<input type='text' name='$name' value='$value' size='$size'>\n";
}

sub ui_select {
    my ($name, $selected, $opts) = @_;
    my $html = "<select name='$name'>\n";
    foreach my $o (@$opts) {
        my $sel = ($o->[0] eq ($selected || '')) ? " selected" : "";
        $html .= "<option value='$o->[0]'$sel>$o->[1]</option>\n";
        }
    $html .= "</select>\n";
    return $html;
}

sub ui_radio {
    my ($name, $selected, $opts) = @_;
    my $html = '';
    foreach my $o (@$opts) {
        my $chk = ($o->[0] eq ($selected || '')) ? " checked" : "";
        $html .= "<input type='radio' name='$name' value='$o->[0]'$chk> $o->[1] ";
        }
    return $html;
}

sub ui_opt_textbox {
    my ($name, $value, $size, $opt_label) = @_;
    return &ui_textbox($name, $value, $size);
}

sub ui_hidden_table_start {
    my ($title, $width, $cols, $id, $open) = @_;
    return "<table id='$id'><tr><th colspan='$cols'>$title</th></tr>\n";
}

sub ui_hidden_table_end {
    my ($id) = @_;
    return "</table>\n";
}

sub ui_textarea {
    my ($name, $value, $rows, $cols) = @_;
    return "<textarea name='$name' rows='$rows' cols='$cols'>$value</textarea>\n";
}

sub ui_checkbox {
    my ($name, $value, $label, $checked) = @_;
    my $chk = $checked ? " checked" : "";
    return "<input type='checkbox' name='$name' value='$value'$chk> $label";
}

sub ui_hr {
    return "<hr>\n";
}

sub ui_buttons_start {
    return "<div class='buttons'>\n";
}

sub ui_buttons_end {
    return "</div>\n";
}

sub ui_buttons_row {
    my ($script, $label, $desc) = @_;
    return "<button>$label</button> $desc\n";
}

sub ui_password {
    my ($name, $value, $size) = @_;
    return "<input type='password' name='$name' size='$size'>\n";
}

sub ui_yesno_radio {
    my ($name, $value) = @_;
    return &ui_radio($name, $value, [ [1, 'Yes'], [0, 'No'] ]);
}

sub ui_print_header {
    my ($title, @rest) = @_;
    # No-op for testing
}

sub ui_print_unbuffered_header {
    my ($title, @rest) = @_;
    # No-op for testing
}

sub ui_print_footer {
    my (@links) = @_;
    # No-op for testing
}

sub ui_columns_start {
    my ($heads) = @_;
    return "<table><tr>" . join("", map { "<th>$_</th>" } @$heads) . "</tr>\n";
}

sub ui_columns_row {
    my ($cols) = @_;
    return "<tr>" . join("", map { "<td>$_</td>" } @$cols) . "</tr>\n";
}

sub ui_columns_end {
    return "</table>\n";
}

sub ui_link {
    my ($url, $text) = @_;
    return "<a href='$url'>$text</a>";
}

# Error handling
sub error {
    die "Webmin error: $_[0]\n";
}

sub error_setup {
    # Store error prefix
}

# Logging (captured for test assertions)
our @_webmin_log;
sub webmin_log {
    my ($action, $type, $object, $params) = @_;
    push(@_webmin_log, { action => $action, type => $type,
                         object => $object, params => $params });
}

# Redirect (captured for test assertions)
our @_redirects;
sub redirect {
    my ($url) = @_;
    push(@_redirects, $url);
}

# Text substitution (Webmin's &text() function)
sub text {
    my ($key, @args) = @_;
    my $str = $text{$key} || $key;
    for (my $i = 0; $i < @args; $i++) {
        my $n = $i + 1;
        $str =~ s/\$$n/$args[$i]/g;
        }
    return $str;
}

# HTML escaping
sub html_escape {
    my ($str) = @_;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    return $str;
}

sub urlize {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $str;
}

# Remote calls (mock — captured for test assertions)
our @_rpc_calls;

# Configurable command responses: pattern => response mapping.
# When backquote_command receives a command matching a pattern key, return
# the configured response instead of the default "ok".
# Values can be:
#   - A simple string (returned with exit code 0)
#   - A hashref { output => "...", exit => N }
our %_mock_cmd_responses;

sub remote_foreign_call {
    my ($server, $module, $func, @args) = @_;
    push(@_rpc_calls, { server => $server, module => $module,
                        func => $func, args => \@args });
    # When used as backquote_command (RPC shell exec), return sentinel output.
    # IMPORTANT: Return a LIST of lines, not a scalar string.
    # This matches real Webmin RPC behavior: backquote_command uses Perl
    # backticks which return a list in list context, and the RPC FIFO
    # subprocess captures in list context.  Callers MUST use
    #   join("", &remote_foreign_call(...))
    # or capture in list context.  Returning a scalar here would hide the
    # list-context bug that caused production failures (scalar(@list) gives
    # the line count, not the content).
    if ($func eq 'backquote_command') {
        my $cmd = $args[0];
        # Check configurable responses first
        foreach my $pattern (keys %_mock_cmd_responses) {
            if ($cmd =~ /$pattern/) {
                my $resp = $_mock_cmd_responses{$pattern};
                if (ref($resp) eq 'HASH') {
                    my $out = defined $resp->{'output'} ? $resp->{'output'} : '';
                    my $rc = defined $resp->{'exit'} ? $resp->{'exit'} : 0;
                    $out .= "\n" if ($out ne '' && $out !~ /\n$/);
                    return ($out, "__RC__=${rc}\n");
                    }
                return ("${resp}\n", "\n__RC__=0\n");
                }
            }
        return ("ok\n", "\n", "__RC__=0\n");
        }
    return 1;
}

# Remote file writes (mock — captured for test assertions)
our @_files_written;
sub remote_write {
    my ($server, $local_file, $remote_file) = @_;
    push(@_files_written, { server => $server, local => $local_file,
                            remote => $remote_file });
    return 1;
}

# Remote require (mock — captured for test assertions)
our @_rpc_require_calls;
sub remote_foreign_require {
    my ($server, $module, $file) = @_;
    push(@_rpc_require_calls, { server => $server, module => $module,
                                file => $file });
    return 1;
}

# Backquote command execution (mock)
our @_commands_run;
sub backquote_command {
    my ($cmd) = @_;
    push(@_commands_run, $cmd);
    return "ok\n";
}

# foreign_require (mock)
sub foreign_require {
    my ($module, $file) = @_;
    # No-op in tests
}

# indexof / indexoflc
sub indexof {
    my ($item, @list) = @_;
    for (my $i = 0; $i < @list; $i++) {
        return $i if ($list[$i] eq $item);
        }
    return -1;
}

sub indexoflc {
    my ($item, @list) = @_;
    $item = lc($item);
    for (my $i = 0; $i < @list; $i++) {
        return $i if (lc($list[$i]) eq $item);
        }
    return -1;
}

# to_ipaddress (mock)
sub to_ipaddress {
    my ($host) = @_;
    return $host =~ /^\d+\.\d+\.\d+\.\d+$/ ? $host : undef;
}

# --- virtual_server namespace stubs ---
package virtual_server;

our %config = ( 'mail' => 0, 'mail_system' => 0 );

our $first_print = sub {
    my ($msg) = @_;
    push(@main::_progress_messages, { type => 'first', msg => $msg });
};

our $second_print = sub {
    my ($msg) = @_;
    push(@main::_progress_messages, { type => 'second', msg => $msg });
};

our %text = ( 'setup_done' => '.. done' );

our @_progress_messages;

# Domain registry: keyed by domain name, values are domain hash refs
our %_mock_domains;
sub mock_add_domain {
    my ($dom_name, $dom_hash) = @_;
    $_mock_domains{$dom_name} = $dom_hash;
}
sub mock_clear_domains {
    %_mock_domains = ();
}

# Domain save capture
our @_saved_domains;

sub get_template { return { 'default' => 1 }; }
sub domain_in { return $_[0]->{'dom'}; }

sub get_domain_by {
    my ($type, $value) = @_;
    return $_mock_domains{$value} if ($type eq 'dom' && exists $_mock_domains{$value});
    return undef;
}

sub list_domains { return values %_mock_domains; }
sub can_edit_domain { return 1; }

sub obtain_lock_dns { }
sub release_lock_dns { }
sub obtain_lock_anything { }
sub release_lock_anything { }
sub register_post_action { }
sub set_domain_envs { }
sub reset_domain_envs { }
sub making_changes { return undef; }
sub made_changes { return undef; }

sub write_as_domain_user {
    my ($d, $sub) = @_;
    $sub->();
}

sub get_domain_dns_records_and_file {
    return ([], '/dev/null');
}

sub create_dns_record {
    return 1;
}

sub delete_dns_record {
    return 1;
}

sub save_domain {
    my ($d) = @_;
    push(@_saved_domains, { %{$d} }) if ($d);
}

sub domain_footer_link {
    my ($d) = @_;
    return "";
}

# Username validation — mirrors the real Virtualmin validation chain:
#   valid_mailbox_name → valid_alias_name → check_username_restrictions
sub valid_alias_name {
    my ($name) = @_;
    if ($name !~ /^[^ \t:\&\(\)\|\;\<\>\*\?\!\/\\]+$/) {
        return "The username contains invalid characters";
        }
    return undef;
}

sub valid_mailbox_name {
    my ($name) = @_;
    my $err = valid_alias_name($name);
    return $err if ($err);
    if ($name eq "domains") {
        return "The username '$name' is reserved";
        }
    if ($name =~ /^\d+/) {
        return "Usernames starting with a number are not allowed";
        }
    return undef;
}

package main;

# Track progress messages for test assertions
our @_progress_messages;

# Declare %access that the library expects
our %access = ( 'dom' => '*' );

# Initialize
&load_language();

# Helper to load plugin library with Webmin init lines skipped
sub load_plugin_lib {
    my ($lib_path) = @_;
    open(my $fh, '<', $lib_path) or die "Cannot open $lib_path: $!";
    my $code = '';
    while (<$fh>) {
        # Skip lines that try to load WebminCore or init Webmin
        next if /^BEGIN\s*\{\s*push/;
        next if /^eval\s+"use WebminCore/;
        next if /^&init_config/;
        next if /^&foreign_require/;
        next if /^our\s+%access\s*=\s*&get_module_acl/;
        $code .= $_;
        }
    close($fh);
    eval $code;
    die "Failed to load $lib_path: $@" if $@;
}

# Helper to load feature hooks (skips require of lib since already loaded)
sub load_plugin_feature {
    my ($feat_path) = @_;
    open(my $fh, '<', $feat_path) or die "Cannot open $feat_path: $!";
    my $code = '';
    while (<$fh>) {
        next if /^require\s+'virtualmin-remote-mail-lib\.pl'/;
        $code .= $_;
        }
    close($fh);

    # Set the input_name that virtual_feature.pl computes
    our $input_name = $module_name;
    $input_name =~ s/[^A-Za-z0-9]/_/g;

    eval $code;
    die "Failed to load $feat_path: $@" if $@;
}

# Helper to run a CGI handler with specific %in params.
# Sets %main::in, evals the handler file, captures output and errors.
# Returns ($output, $error).
sub run_cgi_handler {
    my ($file, %params) = @_;
    %main::in = %params;
    my $output = '';
    open(my $fh, '>', \$output);
    my $old = select($fh);
    my $err;
    eval {
        # Load handler code, skipping the require/ReadParse lines
        open(my $cfh, '<', $file) or die "Cannot open $file: $!";
        my $code = '';
        while (<$cfh>) {
            next if /^#!.*perl/;
            next if /^require\s+'virtualmin-remote-mail-lib\.pl'/;
            next if /^&ReadParse/;
            $code .= $_;
            }
        close($cfh);
        eval $code;
        die $@ if $@;
        };
    $err = $@;
    select($old);
    close($fh);
    return ($output, $err);
}

1;
