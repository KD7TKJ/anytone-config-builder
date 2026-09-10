#!/usr/bin/perl


use strict;
use Text::CSV;
use Scalar::Util qw(looks_like_number);
use Getopt::Long;
use File::Temp qw(tempdir);
use JSON::PP;
use Cwd qw(abs_path);


use constant {
    # There are other fields, but these are the ones we care about
    CHAN_NUM            => 0,
    CHAN_NAME           => 1,
    CHAN_RX_FREQ        => 2,
    CHAN_TX_FREQ        => 3,
    CHAN_MODE           => 4,
    CHAN_POWER          => 5,
    CHAN_BANDWIDTH      => 6,
    CHAN_CTCSS_DEC      => 7,
    CHAN_CTCSS_ENC      => 8,
    CHAN_CONTACT        => 9,
    CHAN_CALL_TYPE_OLD  => 10,
    CHAN_CALL_TYPE_NEW  => 44,
    CHAN_TG_ID          => 45,
    CHAN_TX_PERMIT      => 12,
    CHAN_SQUELCH_MODE   => 13,
    CHAN_COLOR_CODE     => 19,
    CHAN_TIME_SLOT      => 20,
    CHAN_SCANLIST_NAME  => 21,
    CHAN_TX_PROHIBIT    => 23,
    CHAN_DMR_MODE       => 47,
    CHAN_PTT_PROHIBIT   => 48,
    ACB_ZONE_NICKNAME   => 1000,
};


use constant {
    VAL_DIGITAL           => 'D-Digital',
    VAL_ANALOG            => 'A-Analog',
    VAL_NO_TIME_SLOT      => "-", # this is from the input CSV, not a Anytone-ism
    VAL_TX_PERMIT_FREE    => "ChannelFree",
    VAL_TX_PERMIT_SAME    => "Same Color Code",
    VAL_TX_PERMIT_ALWAYS  => "Always",
    VAL_CALL_TYPE_GROUP   => "Group Call",
    VAL_CALL_TYPE_PRIVATE => "Private Call",
    VAL_CTCSS_DCS         => "CTCSS/DCS",
    VAL_DMR_MODE_SIMPLEX  => 0,
    VAL_DMR_MODE_REPEATER => 1,
    LENGTH_CHAN_NAME      => 16,
};


my $global_sort_mode = "alpha";
my $global_hotspot_tx_permit = "same-color-code";
my $global_nickname_mode = "off";
my $global_multi_zone = 0; # default: off
my $global_zone_channel_sort = "processed";    # processed, alpha, id, freq-asc, freq-desc
my $global_scanlist_channel_sort = "processed"; # processed, alpha, id, freq-asc, freq-desc
my $global_json_mode = 0;
my $global_config_directory = "config";
my %json_inputs;
my %json_outputs;

# Startup options
my $global_start_zone1 = "";
my $global_start_zone2 = "";
my $global_start_channel1 = "";
my $global_start_channel2 = "";
my %zone_id_by_name;          # map zone name -> zone number
my $global_optional_settings_filename = "";

my $global_line_number = 0;
my $global_file_name   = 'none';
my $global_channel_number = 1; 
my %channel_csv_field_name;
my %channel_csv_default_value;
my %talkgroup_mapping;
my %zone_config;
my %zone_order;
my $zone_order_default = 9999; # this impacts where the analog and digital-others go.
my $analog_channel_index = 0;
my %scanlist_config;
my %talkgroup_config;
my %talkgroup_order;
my @channel_rows;
my $csv;
my $csv_out;


main();
exit 0;



sub main
{
    my ($analog_filename, $digital_others_filename, $digital_repeaters_filename, $talkgroups_filename,
        $config_directory, $output_directory) = handle_command_line_args();

    if ($global_json_mode)
    {
        run_json_mode();
        return;
    }

    $csv     = Text::CSV_XS->new({binary => 1, auto_diag => 1, always_quote => 1, eol => "\n"});
    $csv_out = Text::CSV_XS->new({binary => 1, auto_diag => 1, always_quote => 1, eol => "\r\n"});

    read_talkgroups($talkgroups_filename);
    read_channel_csv_default( "$config_directory/channel-defaults.csv");

    process_dmr_others_file($digital_others_filename);
    process_dmr_repeater_file($digital_repeaters_filename);
    process_analog_file($analog_filename);

    compute_zone_ids();
    validate_startup_options();

    write_channels_file("$output_directory/channels.csv");
    write_zone_file("$output_directory/zones.csv");
    write_scanlist_file("$output_directory/scanlists.csv");
    write_talkgroup_file("$output_directory/talkgroups.csv");

    # Handle Optional Settings
    my $num_start_opts = count_startup_options();

    if ($num_start_opts == 4) {
        # Always write the stub
        write_optional_settings_stub("$output_directory/OptionalSettings_STUB.csv");
        print "INFO: Optional Settings stub generated.\n";

        # If a template was provided, also write the full override
        if (length($global_optional_settings_filename) > 0) {
            my ($headers_ref, $values_ref) = read_optional_settings_template($global_optional_settings_filename);
            write_optional_settings_full("$output_directory/OptionalSettings_Full.csv", $headers_ref, $values_ref);
            print "INFO: Optional Settings full override generated from template.\n";
        }
    } else {
        if (length($global_optional_settings_filename) > 0) {
            warning("Optional Settings template provided but startup options are missing (all four --start-* options required). Skipping.");
        }
    }
}


################################################################################
################################################################################
################################################################################
##########   CSV OUTPUT ROUTINES
################################################################################
################################################################################
################################################################################

#####
##### Zone file output #####
#####
sub compute_zone_ids
{
    my $row_num = 1;
    %zone_id_by_name = ();

    foreach my $key (sort zone_sort keys %zone_config)
    {
        $zone_id_by_name{$key} = $row_num;
        $row_num++;
    }
}

sub write_channels_file
{
    my ($filename) = @_;

    my $fh = open_output_sink($filename);
    print_channel_header($fh);

    foreach my $row (@channel_rows)
    {
        $csv_out->print($fh, $row);
    }

    close($fh) or error("Couldn't close file '$filename': $!\n");
}

sub open_output_sink
{
    my ($filename) = @_;
    my $fh;

    if ($global_json_mode)
    {
        my $safe_name = safe_output_key($filename);
        if ($safe_name eq '')
        {
            error("Refusing to emit file with unsafe name '$filename'\n");
        }

        $json_outputs{$safe_name} = "";
        open($fh, '>', \$json_outputs{$safe_name})
            or error("Couldn't open in-memory output '$safe_name': $!\n");
        return $fh;
    }

    open($fh, ">$filename") or error("Couldn't open file '$filename': $!\n");
    return $fh;
}

sub write_zone_file
{
    my ($filename) = @_;

    my @headers = ("No.", "Zone Name", 
                  "Zone Channel Member", "Zone Channel Member RX Frequency", "Zone Channel Member TX Frequency", 
                     "A Channel",                  "A Channel RX Frequency",           "A Channel TX Frequency",
                     "B Channel",                  "B Channel RX Frequency",           "B Channel TX Frequency");

    my $fh = open_output_sink($filename);

    $csv_out->print($fh, \@headers);

    my $row_num = 1;
    foreach my $key (sort zone_sort keys %zone_config)
    {
        my $value = $zone_config{$key};
        my $row = zone_row_builder($row_num, $key, $value);

        $csv_out->print($fh, $row);

        $row_num++;
    }

    close($fh) or error("Couldn't close file '$filename': $!\n");
}

sub write_scanlist_file
{
    my ($filename) = @_;

    my @headers = ("No.", "Scan List Name", 
                   "Scan Channel Member", "Scan Channel Member RX Frequency", "Scan Channel Member TX Frequency", 
                   "Scan Mode", "Priority Channel Select", 
                   "Priority Channel 1", "Priority Channel 1 RX Frequency", "Priority Channel 1 TX Frequency",
                   "Priority Channel 2", "Priority Channel 2 RX Frequency", "Priority Channel 2 TX Frequency",
                   "Revert Channel", "Look Back Time A[s]", "Look Back Time B[s]", "Dropout Delay Time[s]", 
                   "Dwell Time[s]");

    generate_csv_file($filename, \@headers, \%scanlist_config, \&scanlist_row_builder, \&case_insensitive_sort);
}


sub write_talkgroup_file
{
    my ($filename) = @_;

    my @headers = ("No.", "Radio ID", "Name", "Country", "Remarks", "Call Type", "Call Alert");

    generate_csv_file($filename, \@headers, \%talkgroup_config, \&talkgroup_row_builder, \&case_insensitive_sort);
}


sub zone_row_builder
{
    my ($zone_number, $zone_name, $zone_record) = @_;

    return generic_row_builder($zone_number, $zone_name, $zone_record, \&zone_row_details, 250, "Zone");
}


sub scanlist_row_builder
{
    my ($scan_number, $scan_name, $scan_record) = @_;

    return generic_row_builder($scan_number, $scan_name, $scan_record, \&scanlist_row_details, 50, "Scanlist");
}


sub talkgroup_row_builder
{
    my ($tg_number, $talkgroup_name, $junk) = @_;

    my $call_type = $talkgroup_config{$talkgroup_name};

    my @values;

    push @values, $tg_number;
    push @values, $talkgroup_mapping{$talkgroup_name};
    push @values, $talkgroup_name;
    push @values, "";
    push @values, "";
    push @values, $call_type;
    push @values, "None";

    return \@values;
}


sub generic_row_builder
{
    my ($row_number, $row_name, $row_record, $row_func, $row_limit, $warning_name) = @_;

    my @values;
    push @values, $row_number;
    push @values, $row_name;

    my @channels;
    my @rx_freqs;
    my @tx_freqs;
    my $i = 0;

    # Determine which sort mode to use based on $warning_name
    my $sort_mode;
    if ($warning_name eq "Zone") {
        $sort_mode = $global_zone_channel_sort;
    } elsif ($warning_name eq "Scanlist") {
        $sort_mode = $global_scanlist_channel_sort;
    } else {
        $sort_mode = "alpha";  # fallback
    }

    # Build a sort key for each entry
    my @sorted_details;
    if ($sort_mode eq "processed") {
        @sorted_details = @{$row_record};  # keep original order
    } else {
        @sorted_details = sort {
            compare_channel_entries($a, $b, $sort_mode)
        } @{$row_record};
    }

    foreach my $row_details (@sorted_details)
    {
        my ($order, $chan_name, $rx_freq, $tx_freq) = split("\t", $row_details);
        $chan_name =~ s/\s+$//;

        if ($row_limit > 0 && $i >= $row_limit)
        {
            warning("$warning_name '$row_name' has more than $row_limit channels. " .
                    "It has been truncated to the first $row_limit channels to keep the CPS software happy.");
            last;
        }

        push @channels, $chan_name;
        push @rx_freqs, $rx_freq;
        push @tx_freqs, $tx_freq;
        $i++;
    }        

    push @values, join("|", @channels);
    push @values, join("|", @rx_freqs);
    push @values, join("|", @tx_freqs);
    $row_func->(\@values, $channels[0], $rx_freqs[0], $tx_freqs[0]);
    return \@values;
}

sub zone_row_details
{
    my ($values_ref, $channel0, $rx0, $tx0) = @_;

    push @{$values_ref}, $channel0;
    push @{$values_ref}, $rx0;
    push @{$values_ref}, $tx0;
    push @{$values_ref}, $channel0;
    push @{$values_ref}, $rx0;
    push @{$values_ref}, $tx0;
}


sub scanlist_row_details
{
    my ($values_ref, $channel0, $rx0, $tx0) = @_;

    push @{$values_ref}, "Off";
    push @{$values_ref}, "Off";
    push @{$values_ref}, "";
    push @{$values_ref}, "";
    push @{$values_ref}, "Off";
    push @{$values_ref}, "";
    push @{$values_ref}, "";
    push @{$values_ref}, "Selected";
    push @{$values_ref}, "0.5";
    push @{$values_ref}, "0.5";
    push @{$values_ref}, "0.1";
    push @{$values_ref}, "0.1";
}


#####
#####  Generic CSV file writer given a hash of data
#####
sub generate_csv_file
{
    my ($filename, $headers, $data, $row_func, $sort_func) = @_;

    my $fh = open_output_sink($filename);

    $csv_out->print($fh, $headers);

    my $row_num = 1;
    foreach my $key (sort $sort_func keys %{$data})
    {
        my $value = $data->{$key};
        my $row = $row_func->($row_num, $key, $value);

        $csv_out->print($fh, $row);

        $row_num++;
    }

    close($fh) or error("Couldn't close file '$filename': $!\n");
}


sub print_channel_header
{
    my ($out_fh) = @_;

    my @output;
    foreach my $index (sort {$a <=> $b} keys %channel_csv_field_name)
    {
        push @output, $channel_csv_field_name{$index};
    } 

    $csv_out->print($out_fh, \@output);
}


##########
####  Sort Functions
##########
sub zone_sort
{
    my $a_i = $zone_order{$a};
    my $b_i = $zone_order{$b};

    # If we're in alphabetical mode or if the zone indexes are the same (which will be the case if we're in
    # non-alphabetical mode for the analog and digital-other channels).
    if ($global_sort_mode eq 'alpha' or $a_i == $b_i)
    {
        return lc($a) cmp lc($b);
    }
    else
    {
        return $a_i <=> $b_i
    }
}


sub case_insensitive_sort
{
    # no fancy scanning rules here
    return lc($a) cmp lc($b);
}



################################################################################
################################################################################
################################################################################
##########   CSV INPUT ROUTINES
################################################################################
################################################################################
################################################################################



#####
#  Analog CSV 
#####
sub process_analog_file
{
    my ($filename) = @_;

    my @header = ("Zone", "Channel Name", "Bandwidth", "Power", 
                  "RX Freq", "TX Freq", "CTCSS Decode", "CTCSS Encode",
                  "TX Prohibit");

    process_csv_file_with_header($filename, "Analog", \@header, \&analog_csv_field_extractor);
}

sub analog_csv_field_extractor
{
    my ($row) = @_;

    my %chan_config;
    $chan_config{+CHAN_SCANLIST_NAME}   = validate_zone(        $row->[0]);
    $chan_config{+CHAN_NAME}            = validate_name(        $row->[1]);
    $chan_config{+CHAN_BANDWIDTH}       = validate_bandwidth(   $row->[2]);
    $chan_config{+CHAN_POWER}           = validate_power(       $row->[3]);
    $chan_config{+CHAN_RX_FREQ}         = validate_freq(        $row->[4]);
    $chan_config{+CHAN_TX_FREQ}         = validate_freq(        $row->[5]);
    $chan_config{+CHAN_CTCSS_DEC}       = validate_ctcss(       $row->[6]);
    $chan_config{+CHAN_CTCSS_ENC}       = validate_ctcss(       $row->[7]);
    $chan_config{+CHAN_TX_PROHIBIT}     = validate_tx_prohibit( $row->[8]);
    $chan_config{+CHAN_PTT_PROHIBIT}    = validate_tx_prohibit( $row->[8]);
    $chan_config{+CHAN_MODE}            = VAL_ANALOG;

    if ($chan_config{+CHAN_CTCSS_DEC} ne "Off")
    {
        $chan_config{+CHAN_SQUELCH_MODE} = VAL_CTCSS_DCS;
    }

    return \%chan_config;
}


#####
## DMR Others CSV
#####
sub process_dmr_others_file
{
    my ($filename) = @_;

    my @header = ("Zone", "Channel Name", "Power", "RX Freq", "TX Freq", "Color Code", "Talk Group", "TimeSlot", 
                  "Call Type", "TX Permit");

    process_csv_file_with_header($filename, "Digital-Others", \@header, \&dmr_others_csv_field_extractor);
}

sub dmr_others_csv_field_extractor
{
    my ($row) = @_;

    my %chan_config;
    $chan_config{+CHAN_SCANLIST_NAME}   = validate_zone(        $row->[0]);
    $chan_config{+CHAN_NAME}            = validate_name(        $row->[1]);
    $chan_config{+CHAN_POWER}           = validate_power(       $row->[2]);
    $chan_config{+CHAN_RX_FREQ}         = validate_freq(        $row->[3]);
    $chan_config{+CHAN_TX_FREQ}         = validate_freq(        $row->[4]);
    $chan_config{+CHAN_COLOR_CODE}      = validate_color_code(  $row->[5]);
    $chan_config{+CHAN_CONTACT}         = validate_contact(     $row->[6]);
    $chan_config{+CHAN_TG_ID}           = $talkgroup_mapping    {$row->[6]};
    $chan_config{+CHAN_TIME_SLOT}       = validate_timeslot(    $row->[7]);  
    $chan_config{+CHAN_CALL_TYPE_OLD}   = validate_call_type(   $row->[8]); 
    $chan_config{+CHAN_CALL_TYPE_NEW}   = validate_call_type(   $row->[8]); 
    $chan_config{+CHAN_TX_PERMIT}       = validate_tx_permit(   $row->[9]); 
    $chan_config{+CHAN_DMR_MODE}        = dmr_mode(             \%chan_config);
    $chan_config{+CHAN_MODE}            = VAL_DIGITAL;


    return \%chan_config;
}





#####
# DMR Repeater CSV
#####

sub process_dmr_repeater_file
{
    my ($filename) = @_;

    my @header = ("Zone Name", "Comment", "Power", "RX Freq", "TX Freq", "Color Code");

    process_csv_file_with_header($filename, "Digital-Repeater", \@header, \&dmr_repeater_csv_field_extractor, 
                                                                               \&dmr_repeater_csv_matrix_extractor);
}

sub dmr_repeater_csv_field_extractor
{
    my ($row) = @_;

    my %chan_config;

    my ($zone_full, $zone_nick) = handle_nickname_values($row->[0]);

    $chan_config{+CHAN_SCANLIST_NAME}   = validate_zone(       $zone_full);
    $chan_config{+ACB_ZONE_NICKNAME}    = validate_zone(       $zone_nick);
                                                             # $row->[1] is a comment column
    $chan_config{+CHAN_POWER}           = validate_power(      $row->[2]);
    $chan_config{+CHAN_RX_FREQ}         = validate_freq(       $row->[3]);
    $chan_config{+CHAN_TX_FREQ}         = validate_freq(       $row->[4]);
    $chan_config{+CHAN_COLOR_CODE}      = validate_color_code( $row->[5]);
    $chan_config{+CHAN_DMR_MODE}        = dmr_mode(            \%chan_config);
    $chan_config{+CHAN_MODE}            = VAL_DIGITAL;

    return \%chan_config;
}

sub dmr_repeater_csv_matrix_extractor
{
    my ($chan_config, $contact, $value) = @_;
    
    my $do_multiply = 0;

    my ($timeslot, $call_type) = handle_repeater_value($value);

    $timeslot = validate_timeslot($timeslot);
    if ($timeslot ne VAL_NO_TIME_SLOT)
    { 
        my ($contact, $chan_nick) = handle_nickname_values($contact);

        my $chan_name = make_channel_name($chan_config->{+ACB_ZONE_NICKNAME}, $contact, $chan_nick);

        $chan_config->{+CHAN_CONTACT}       = validate_contact($contact);
        $chan_config->{+CHAN_TG_ID}         = $talkgroup_mapping{$contact};
        $chan_config->{+CHAN_TIME_SLOT}     = validate_timeslot($timeslot);
        $chan_config->{+CHAN_NAME}          = validate_channel_name($chan_name);
        $chan_config->{+CHAN_CALL_TYPE_OLD} = validate_call_type($call_type);
        $chan_config->{+CHAN_CALL_TYPE_NEW} = validate_call_type($call_type);
        $do_multiply = 1;
    }

    return ($do_multiply, $chan_config);
}




#####
#####
## These two routines are basically the same... let's extract the common parts and make this generic
#####
#####
sub read_config_file
{
    my ($path) = @_;
    open(my $fh, '<:crlf', $path)
        or error("Couldn't open config file '$path': $!\n");
    return $fh;
}

sub safe_output_key
{
    my ($filename) = @_;
    my $key = $filename;
    $key =~ s{.*[/\\]}{};
    $key =~ s/[^A-Za-z0-9._-]/_/g;
    $key =~ s/^\.+//;
    return $key;
}

sub read_channel_csv_default
{
    my ($filename) = @_;

    my $fh = read_config_file($filename);

    for(my $line_no = 0; my $row = $csv->getline($fh); $line_no++)
    {
        $channel_csv_field_name{   $row->[0]} = $row->[1];
        $channel_csv_default_value{$row->[0]} = $row->[2];
    }
   
    close($fh); 
}

sub json_response
{
    my ($payload) = @_;
    my $json = JSON::PP->new->canonical->encode($payload);
    print STDOUT $json;
    exit 0;
}

sub analyze_csv_inputs
{
    my ($input_map) = @_;
    my %zones;
    my $csv_parser = Text::CSV_XS->new({binary => 1, auto_diag => 1});

    for my $input_name (qw(analog digital_others digital_repeaters))
    {
        my $source = $input_map->{$input_name};
        next if (!defined $source || $source eq '');

        my $temp_file = File::Temp::tempnam('/tmp', 'acb-json-');
        open(my $tmp_fh, '>:raw', $temp_file) or next;
        print {$tmp_fh} $source;
        close($tmp_fh);

        open(my $fh, '<:crlf', $temp_file) or next;
        my $first = 1;
        while (my $row = $csv_parser->getline($fh))
        {
            next if $first;
            $first = 0;
            my $zone_name = $row->[0] // '';
            my $channel_name = $row->[1] // '';
            next if ($zone_name eq '' || $channel_name eq '');
            push @{ $zones{$zone_name} }, $channel_name;
        }
        close($fh);
        unlink $temp_file;
    }

    my @zone_list;
    for my $name (sort { lc($a) cmp lc($b) } keys %zones)
    {
        my @channels = sort { lc($a) cmp lc($b) } @{ $zones{$name} };
        push @zone_list, { name => $name, channels => \@channels };
    }

    return \@zone_list;
}

sub run_json_mode
{
    my $raw = do { local $/; <STDIN> };
    my $request = eval { JSON::PP->new->decode($raw) };
    if (!defined $request || ref($request) ne 'HASH')
    {
        json_response({ status => 'error', message => 'Invalid JSON request' });
    }

    my $safe_mode = $request->{mode} // 'build';
    $safe_mode =~ s/[^A-Za-z0-9_-]/_/g;

    my $inputs = $request->{inputs} // {};
    my $options = $request->{options} // {};
    my $startup = $request->{startup} // {};
    $global_sort_mode = $options->{sorting} // $global_sort_mode;
    $global_hotspot_tx_permit = $options->{hotspot_tx_permit} // $global_hotspot_tx_permit;
    $global_nickname_mode = $options->{nicknames} // $global_nickname_mode;
    $global_multi_zone = $options->{multi_zone} ? 1 : $global_multi_zone;
    $global_zone_channel_sort = $options->{zone_channel_sort} // $global_zone_channel_sort;
    $global_scanlist_channel_sort = $options->{scanlist_channel_sort} // $global_scanlist_channel_sort;

    $global_start_zone1 = $startup->{zone1} // $startup->{start_zone1} // $global_start_zone1;
    $global_start_zone2 = $startup->{zone2} // $startup->{start_zone2} // $global_start_zone2;
    $global_start_channel1 = $startup->{channel1} // $startup->{start_channel1} // $global_start_channel1;
    $global_start_channel2 = $startup->{channel2} // $startup->{start_channel2} // $global_start_channel2;

    if (($request->{mode} // 'build') eq 'analyze')
    {
        my $zones = analyze_csv_inputs($inputs);
        json_response({ status => 'ok', zones => $zones, warnings => [], info => [] });
    }

    my @required = qw(analog digital_others digital_repeaters talkgroups);
    for my $name (@required)
    {
        next if (defined $inputs->{$name} && $inputs->{$name} ne '');
        json_response({ status => 'error', message => "Missing required input: $name" });
    }

    $csv     = Text::CSV_XS->new({binary => 1, auto_diag => 1, always_quote => 1, eol => "\n"});
    $csv_out = Text::CSV_XS->new({binary => 1, auto_diag => 1, always_quote => 1, eol => "\r\n"});

    my $workdir = File::Temp::tempdir('acb-json-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    for my $name (@required)
    {
        my $path = "$workdir/$name.csv";
        if (defined $inputs->{$name} && $inputs->{$name} ne '')
        {
            open(my $fh, '>:raw', $path) or json_response({ status => 'error', message => "Couldn't write $name.csv" });
            print {$fh} $inputs->{$name};
            close($fh);
        }
    }

    read_talkgroups("$workdir/talkgroups.csv");
    read_channel_csv_default("$global_config_directory/channel-defaults.csv");

    $global_json_mode = 1;
    %json_outputs = ();
    @channel_rows = ();

    process_dmr_others_file("$workdir/digital_others.csv");
    process_dmr_repeater_file("$workdir/digital_repeaters.csv");
    process_analog_file("$workdir/analog.csv");

    compute_zone_ids();
    validate_startup_options();

    write_channels_file("channels.csv");
    write_zone_file("zones.csv");
    write_scanlist_file("scanlists.csv");
    write_talkgroup_file("talkgroups_out.csv");

    my $num_start_opts = count_startup_options();
    if ($num_start_opts == 4) {
        write_optional_settings_stub("OptionalSettings_STUB.csv");
        if (length($global_optional_settings_filename) > 0) {
            my ($headers_ref, $values_ref) = read_optional_settings_template($global_optional_settings_filename);
            write_optional_settings_full("OptionalSettings_Full.csv", $headers_ref, $values_ref);
        }
    }

    my %files;
    for my $filename (qw(channels.csv zones.csv scanlists.csv talkgroups_out.csv OptionalSettings_STUB.csv OptionalSettings_Full.csv))
    {
        my $safe_name = safe_output_key($filename);
        if ($safe_name eq '') {
            json_response({ status => 'error', message => "Refusing to emit file with unsafe name '$filename'" });
        }
        if (exists $json_outputs{$safe_name}) {
            $files{$safe_name} = $json_outputs{$safe_name};
        }
    }

    json_response({ status => 'ok', files => \%files, warnings => [], info => [] });
}


sub read_talkgroups
{
    my ($filename) = @_;

    open(my $fh,  '<:crlf', $filename) or error("Couldn't open file '$filename': $!\n");

    my $index = 1;
    for(my $line_no = 0; my $row = $csv->getline($fh); $line_no++)
    {
        $talkgroup_mapping{$row->[0]} = $row->[1];
        $talkgroup_order{$row->[0]} = $index++;
    }
   
    close($fh); 
}




#####
#####
## This is where a lot of the magic happens... 
#####
#####

# This is where we read the input CSV files.  This is a fairly generic routine that is driven by it's arguments.
# Specifically, it takes a few function references to do the actual "hard work" of extracting the relevant fields
# into a "chan_config" hash which then gets passed into the "add_channel" routine at the end.
#
# This is made slightly more intersting/complicated by the fact that our repeaters input has a few columns that are
# the same for every channel (frequencies and such), but then has a big matrix of talk groups that are available on
# the repeater.  So, this routine ALSO does the "matrix multiplication" (probably a poor word choice) by extracting
# the talk group names and then multiplying out the row into a channel for each talkgroup that's on the repeater.
#
sub process_csv_file_with_header
{
    my ($filename, $file_nickname, $header_ref, $field_extractor, $matrix_field_extractor) = @_;

    my @headers;

    $global_file_name = $file_nickname;

    my $zone_order_index = 1;
    open(my $fh,  '<:crlf', $filename) or error("Couldn't open file '$filename': $!\n");
    for(my $line_no = 0; my $row = $csv->getline($fh); $line_no++)	
    {
        $global_line_number = $line_no;
        # Make sure the header looks sane... it's an easy check, but it'll catch obvious mistakes
        if ($line_no == 0)
        {
            # iterate through the headers that were provided in the arguments and make sure they match
            # what's in the file.
            for(my $col = 0; $col < scalar(@{$header_ref}); $col++)
            {
                if ($row->[$col] ne $header_ref->[$col])
                {
                    error("CSV header does not match for $file_nickname file (found '" 
                       . $row->[$col] ."' expected '" . $header_ref->[$col] . "')\n");
                }
                push @headers, $row->[$col];
            }   


            # If this is going to be a matrix'd CSV, those headers will follow the main headers
            for(my $col = scalar(@{$header_ref}); $col < scalar(@{$row}); $col++)
            {
                push @headers, $row->[$col];
            }

        }
        else  ## Process an actual data row...
        {

            my $chan_config = $field_extractor->($row);
            my $zone_name = $chan_config->{+CHAN_SCANLIST_NAME};

            # non-matrixed CSV files:
            if (scalar(@{$header_ref}) == scalar(@{$row}))
            {
                # This area applies to the Analog and "Other DMR" inputs...
                # Each of those files has a "zone" column.  We'll create a zone and a scanlist with all the channels
                # listed in the specified zone.
                # ... this is a hack and shouldn't live here =/
                my $scanlist_name = $chan_config->{+CHAN_SCANLIST_NAME};

                add_channel($chan_config, $zone_name, $scanlist_name, $zone_order_default);
            }

            # matrixed CSV files... so iterate through each of the extra headers, which are the talk groups...
            for (my $col = scalar(@{$header_ref}); $col < scalar(@{$row}); $col++)
            {
                if (!defined($matrix_field_extractor))
                {
                    error("There are too many columns in '$file_nickname' file, line $line_no.\n");
                }
                my ($do_matrix, $chan_config) = $matrix_field_extractor->($chan_config, $headers[$col], $row->[$col]);


                if ($do_matrix)
                {
                    # For the repeaters, we create a zone per repeater, and a scanlist for each talkgroup (which allows
                    # us to scan this talkgroup across all repeaters).  We also set the scanlist_name to the talkgroup
                    # so that when we hit scan, we actually scan the right thing ;-P
                    #
                    # again, this is a hack and shouldn't live here.
                    my $scanlist_name = $chan_config->{+CHAN_CONTACT};
                    $chan_config->{+CHAN_SCANLIST_NAME} = $scanlist_name;

                    $chan_config->{+CHAN_TX_PERMIT} = tx_permit($chan_config);

                    add_channel($chan_config, $zone_name, $scanlist_name, $zone_order_index);
                }
            }
            $zone_order_index++;
        }
    }
}


sub add_channel
{
    my ($chan_config, $zone_name, $scanlist_name, $zone_order_index) = @_;

    my @output;

    foreach my $index (sort {$a <=> $b} keys %channel_csv_default_value)
    {
        my $value = $channel_csv_default_value{$index};
        if(defined($chan_config->{$index}))
        {
            $value = $chan_config->{$index};
        }
        if ($index == CHAN_NUM)
        {
            $value = $global_channel_number++;
        }

        $chan_config->{$index} = $value;

        if ($value eq "REQUIRED")
        {
            error("I need a value for '" . $channel_csv_field_name{$index} . "'\n");
        }

        push @output, $value; 
    }

    push @channel_rows, \@output;

    build_zone_config(     $chan_config, $zone_name, $zone_order_index);
    build_scanlist_config( $chan_config, $scanlist_name);
    if ($chan_config->{+CHAN_MODE} eq VAL_DIGITAL) {
        build_talkgroup_config($chan_config, $zone_name);
    } 
}

sub build_zone_config
{
    my ($chan_config, $zone_string, $zone_order_index) = @_;

    my $chan_name = $chan_config->{+CHAN_NAME};
    my $rx_freq   = $chan_config->{+CHAN_RX_FREQ};
    my $tx_freq   = $chan_config->{+CHAN_TX_FREQ};
    my $order     = channel_order_name($chan_config);

    my @zone_names;
    if ($global_multi_zone)
    {
        @zone_names = split(/\|/, $zone_string);
        # trim each
        @zone_names = map { s/^\s+|\s+$//g; $_ } @zone_names;
        @zone_names = grep { $_ ne '' } @zone_names;
    }
    else
    {
        @zone_names = ($zone_string);
    }

    foreach my $zone_name (@zone_names)
    {
        $zone_order{$zone_name} = $zone_order_index;
        push @{$zone_config{$zone_name}}, join("\t", $order, $chan_name, $rx_freq, $tx_freq);
    }
}

sub build_scanlist_config
{
    my ($chan_config, $scanlist_string) = @_;

    my $chan_name = $chan_config->{+CHAN_NAME};
    my $rx_freq   = $chan_config->{+CHAN_RX_FREQ};
    my $tx_freq   = $chan_config->{+CHAN_TX_FREQ};
    my $order     = channel_order_name($chan_config);

    my @scanlist_names;
    if ($global_multi_zone)
    {
        @scanlist_names = split(/\|/, $scanlist_string);
        @scanlist_names = map { s/^\s+|\s+$//g; $_ } @scanlist_names;
        @scanlist_names = grep { $_ ne '' } @scanlist_names;
    }
    else
    {
        @scanlist_names = ($scanlist_string);
    }

    foreach my $scan_name (@scanlist_names)
    {
        push @{$scanlist_config{$scan_name}}, join("\t", $order, $chan_name, $rx_freq, $tx_freq);
    }
}

sub build_talkgroup_config
{
    my ($chan_config, $zone_name) = @_;

    my $talkgroup = $chan_config->{+CHAN_CONTACT};
    my $call_type = $chan_config->{+CHAN_CALL_TYPE_OLD};
    

    if (!defined($talkgroup_mapping{$talkgroup}))
    {
        error("Talkgroup '$talkgroup' is referenced but not defined in the talkgroup input CSV file\n");
    }

    if (defined($talkgroup_config{$talkgroup}) && $talkgroup_config{$talkgroup} ne $call_type)
    {
        my $other_call_type = $talkgroup_config{$talkgroup};
        my $chan_name = $chan_config->{+CHAN_NAME};
        my $rx_freq   = $chan_config->{+CHAN_RX_FREQ};
        my $tx_freq   = $chan_config->{+CHAN_TX_FREQ};

        error("Talkgroup '$talkgroup' was previously identified as a '$other_call_type', but is now trying to be "
            . "used as a '$call_type' on channel '$chan_name' (Zone: '$zone_name', RX: $rx_freq, TX: $tx_freq).  "
            . "The Anytone CPS won't allow this to be imported.   To fix this, create a second entry in your "
            . "talkgroups CSV input file for this talkgroup with a different name.\n");
    }

    $talkgroup_config{$talkgroup} = $call_type;
}


sub channel_order_name
{
    my ($chan_config) = @_;

    my $index1 = $zone_order_default;
    my $index2 = 0;
    my $chan_name = $chan_config->{+CHAN_NAME};

    if ($global_sort_mode ne 'alpha' )
    {
        if ($chan_config->{+CHAN_MODE} eq VAL_DIGITAL)
        {
            if (defined($talkgroup_order{$chan_config->{+CHAN_CONTACT}}))
            {
                $index1 = $talkgroup_order{$chan_config->{+CHAN_CONTACT}};
            }
        }
        elsif ($chan_config->{+CHAN_MODE} eq VAL_ANALOG)
        {
            $index2 = $analog_channel_index++;
        }
    }

    return sprintf("%04d%04d%s", $index1, $index2, $chan_name);

}


sub tx_permit
{
    my ($chan_config) = @_;

    my $result = VAL_TX_PERMIT_SAME;
    if($global_hotspot_tx_permit eq "always" && $chan_config->{+CHAN_RX_FREQ} eq $chan_config->{+CHAN_TX_FREQ})
    {
        $result = VAL_TX_PERMIT_ALWAYS;
    }

    return $result;
}

sub dmr_mode
{
    my ($chan_config) = @_;

    my $result = VAL_DMR_MODE_SIMPLEX;
    if ($chan_config->{+CHAN_RX_FREQ} ne $chan_config->{+CHAN_TX_FREQ})
    {
        $result = VAL_DMR_MODE_REPEATER;
    }

    return $result;
}



sub handle_repeater_value
{
    my ($value) = @_;

    my @subvalues = split(';', $value);

    my $timeslot = shift(@subvalues);

    my $call_type = VAL_CALL_TYPE_GROUP;
    foreach my $v (@subvalues)
    {
        $call_type = VAL_CALL_TYPE_PRIVATE if ($v eq "P");
    }

    return ($timeslot, $call_type);
}

sub handle_nickname_values
{
    my ($value) = @_;

    #  OLY;Olympia/Cap Pk.
    my @subvalues = split(';', $value);

    my $full = shift(@subvalues);
    my $nick = '';
    foreach my $v (@subvalues)
    {
        $nick = $v;
    }

    return ($full, $nick);
}

sub make_channel_name
{
    my ($zone_nick, $chan_full, $chan_nick) = @_;

    if ($global_nickname_mode eq 'off' || length($zone_nick) == 0)
    {
        return $chan_full;
    }

    if (length($chan_nick) == 0)
    {
        $chan_nick = $chan_full;
    }

    if ($global_nickname_mode eq 'prefix-forced' || $global_nickname_mode eq 'suffix-forced')
    {
        $chan_full = $chan_nick;
    }

    my ($chan_name, $sep);
    if (length($zone_nick) + length($chan_full) + 1 <= LENGTH_CHAN_NAME)
    {
        $chan_name = $chan_full;
        $sep = ' ';
    }
    elsif(length($zone_nick) + length($chan_nick) + 1 <= LENGTH_CHAN_NAME)
    {
        $chan_name = $chan_nick;
        $sep = ' ';
    }
    elsif(length($zone_nick) + length($chan_nick) <= LENGTH_CHAN_NAME)
    {
        $chan_name = $chan_nick;
        $sep = '';
    }
    else
    {
        error("Can't make a channel name fit into 16 characters for '$zone_nick' and '$chan_nick'");
    }

    # some people like to prefix their nicknames with "-" or "/", drop the space in that case
    if ($zone_nick !~ /^[A-Za-z0-9]/)
    {
        $sep = '';
    }

    if ($global_nickname_mode eq 'prefix' || $global_nickname_mode eq 'prefix-forced')
    {
        return $zone_nick . $sep . $chan_name;
    }
    else
    {
        return $chan_name . $sep . $zone_nick;
    }
        
}


################################################################################
################################################################################
################################################################################
##########   STARTUP OPTIONS
################################################################################
################################################################################
################################################################################

sub read_optional_settings_template
{
    my ($filename) = @_;

    my @headers;
    my @values;

    open(my $fh, '<:crlf', $filename) or error("Couldn't open file '$filename': $!\n");

    # Read the header row
    my $header_row = $csv->getline($fh);
    if (!$header_row) {
        error("Optional Settings file '$filename' is empty or invalid.\n");
    }

    @headers = @{$header_row};

    # Read the values row (should be exactly one row of data)
    my $value_row = $csv->getline($fh);
    if (!$value_row) {
        error("Optional Settings file '$filename' has no data row.\n");
    }

    @values = @{$value_row};

    close($fh);

    return (\@headers, \@values);
}

sub count_startup_options
{
    my $count = 0;
    $count++ if (defined($global_start_zone1) && length($global_start_zone1) > 0);
    $count++ if (defined($global_start_zone2) && length($global_start_zone2) > 0);
    $count++ if (defined($global_start_channel1) && length($global_start_channel1) > 0);
    $count++ if (defined($global_start_channel2) && length($global_start_channel2) > 0);
    return $count;
}

sub find_channel_position
{
    my ($zone_name, $channel_name) = @_;

    # Get the list of channels for this zone
    my $zone_record = $zone_config{$zone_name};
    return 0 unless defined($zone_record);

    my $pos = 1;
    foreach my $entry (@{$zone_record}) {
        my ($order, $chan_name, $rx_freq, $tx_freq) = split("\t", $entry);
        if ($chan_name eq $channel_name) {
            return $pos;
        }
        $pos++;
    }

    return 0;  # Not found
}

sub validate_startup_options
{
    # If no startup options are set, skip validation
    return 1 if (!defined($global_start_zone1) || length($global_start_zone1) == 0);

    # Check if zones exist
    if (!exists $zone_id_by_name{$global_start_zone1}) {
        error("Startup zone 1 '$global_start_zone1' does not exist in the output zones.\n");
    }
    if (!exists $zone_id_by_name{$global_start_zone2}) {
        error("Startup zone 2 '$global_start_zone2' does not exist in the output zones.\n");
    }

    # Check if channels exist in their respective zones
    my $chan1_pos = find_channel_position($global_start_zone1, $global_start_channel1);
    if (!$chan1_pos) {
        error("Startup channel 1 '$global_start_channel1' is not in startup zone 1 '$global_start_zone1'.\n");
    }

    my $chan2_pos = find_channel_position($global_start_zone2, $global_start_channel2);
    if (!$chan2_pos) {
        error("Startup channel 2 '$global_start_channel2' is not in startup zone 2 '$global_start_zone2'.\n");
    }

    return 1;
}

sub write_optional_settings_stub
{
    my ($filename) = @_;

    my @headers = ("StartChUse", "StartZone1", "StartZone2", "StartCurChan1", "StartCurChan2");

    my $fh = open_output_sink($filename);

    $csv_out->print($fh, \@headers);

    # StartChUse: 1 = On (since options are provided)
    my $start_ch_use = 1;

    # Zones: 0-based
    my $zone1_id = $zone_id_by_name{$global_start_zone1} - 1;
    my $zone2_id = $zone_id_by_name{$global_start_zone2} - 1;

    # Channels: 1-based (position within zone)
    my $chan1_pos = find_channel_position($global_start_zone1, $global_start_channel1);
    my $chan2_pos = find_channel_position($global_start_zone2, $global_start_channel2);

    # Safety fallback (shouldn't happen if validation passed)
    $chan1_pos = 1 unless $chan1_pos;
    $chan2_pos = 1 unless $chan2_pos;

    my @values = ($start_ch_use, $zone1_id, $zone2_id, $chan1_pos, $chan2_pos);
    $csv_out->print($fh, \@values);

    close($fh) or error("Couldn't close file '$filename': $!\n");
}

sub write_optional_settings_full
{
    my ($filename, $headers_ref, $values_ref) = @_;

    # Build index of column names
    my %col_index;
    for (my $i = 0; $i < scalar(@{$headers_ref}); $i++) {
        $col_index{$headers_ref->[$i]} = $i;
    }

    my @required_cols = ("StartChUse", "StartZone1", "StartZone2", "StartCurChan1", "StartCurChan2");
    my @missing_cols;
    foreach my $col (@required_cols) {
        if (!exists $col_index{$col}) {
            push @missing_cols, $col;
        }
    }

    # Stop with a clear error if any required columns are missing
    if (@missing_cols) {
        error("Required column(s) not found in Optional Settings template: " . join(", ", @missing_cols) . "\n"
            . "Please ensure your template matches the expected CPS export format.\n");
    }

    # Apply overrides
    my @new_values = @{$values_ref};
    $new_values[$col_index{"StartChUse"}] = 1;  # On
    $new_values[$col_index{"StartZone1"}] = $zone_id_by_name{$global_start_zone1} - 1;
    $new_values[$col_index{"StartZone2"}] = $zone_id_by_name{$global_start_zone2} - 1;
    $new_values[$col_index{"StartCurChan1"}] = find_channel_position($global_start_zone1, $global_start_channel1);
    $new_values[$col_index{"StartCurChan2"}] = find_channel_position($global_start_zone2, $global_start_channel2);

    my $fh = open_output_sink($filename);
    $csv_out->print($fh, $headers_ref);
    $csv_out->print($fh, \@new_values);
    close($fh) or error("Couldn't close file '$filename': $!\n");
}


################################################################################
################################################################################
################################################################################
##########   DATA VALIDATION ROUTINES
################################################################################
################################################################################
################################################################################

sub validate_bandwidth
{
    my ($mode) = @_;

    my %valid_modes = ( "25K" => 1, "12.5K" =>1 );

    return _validate_membership($mode, \%valid_modes, "Analog Mode");
}

sub validate_call_type
{
    my ($call_type) = @_;
    
    my %valid_call_types = ("Private Call" => 1, "Group Call" => 1);
    
    return _validate_membership($call_type, \%valid_call_types, "Call Type");    
}

sub validate_channel_name
{
    my ($contact) = @_;

    return _validate_string_length('Channel Name', $contact, LENGTH_CHAN_NAME);

}

sub validate_color_code
{
    my ($color_code) = @_;
    return _validate_num_in_range("Color Code", $color_code, 0, 16);
}


sub validate_contact
{
    my ($contact) = @_;

    return _validate_string_length("Contact (aka Talk Group)", $contact, LENGTH_CHAN_NAME);
}


sub validate_ctcss
{
    my ($ctcss) = @_;
    return $ctcss if ($ctcss eq 'Off');
    return $ctcss if ($ctcss =~ /D[0-9A-Za-z]+/ && length($ctcss) < 10); # DCS tones, could be smarter
    return _validate_num_in_range('CTCSS/DCS', $ctcss, 0, 300); # this could be smarter
}

sub validate_freq
{
    my ($freq) = @_;
    return _validate_num_in_range('Frequency', $freq, 0, 500); # this could be smarter too
}

sub validate_name
{
    my ($name) = @_;

    return _validate_string_length('Channel Name', $name, LENGTH_CHAN_NAME);
}

sub validate_power
{
    my ($power) = @_;

    my %valid_power_levels = ("Low" => 1, "Mid" => 1, "High" => 1, "Turbo" => 1);

    return _validate_membership($power, \%valid_power_levels, "Power Level");
}

sub validate_timeslot
{
    my ($timeslot) = @_;

    my %valid_timeslots = ("1" => 1, "2" => 1, "-" => 1);

    return _validate_membership($timeslot, \%valid_timeslots, "Time Slot");
}

sub validate_tx_permit
{
    my ($tx_permit) = @_;

    my %valid_tx_permits = ("Always" => 1, "ChannelFree" => 1, "Same Color Code" => 1, "Different Color Code" => 1);

    return _validate_membership($tx_permit, \%valid_tx_permits, "TX Permit");
}

sub validate_tx_prohibit
{
    my ($tx_prohibit) = @_;
    
    return _validate_on_off($tx_prohibit, "TX Prohibit");
}

sub validate_zone
{
    my ($zone_string) = @_;

    if ($global_multi_zone)
    {
        my @multiple_zones = split(/\|/, $zone_string);
        foreach my $single_zone (@multiple_zones)
        {
            $single_zone =~ s/^\s+|\s+$//g;
            next if $single_zone eq '';
            _validate_string_length('Zone', $single_zone, 16);
        }
        return $zone_string;
    }
    else
    {
        # Original: treat the whole string as one zone name
        return _validate_string_length('Zone', $zone_string, 16);
    }
}

sub validate_sort_mode
{
    my ($sort_order) = @_;

    my %valid_sort_orders = ("alpha" => 1, "repeaters-first" => 1, "analog-first" => 1);

    return _validate_membership($sort_order, \%valid_sort_orders, "Sort Order");
}

sub validate_hotspot_mode
{
    my ($hotspot_mode) = @_;

    my %valid_modes = ("always" => 1, "same-color-code" => 1);

    return _validate_membership($hotspot_mode, \%valid_modes, "Hotspot TX Permit");
}

sub validate_nickname_mode
{
    my ($nickname_mode) = @_;

    my %valid_modes = ("off" => 1, "prefix" => 1, "suffix" => 1, "prefix-forced" => 1, "suffix-forced" => 1);

    return _validate_membership($nickname_mode, \%valid_modes, "Nickname Mode");
}

sub validate_channel_sort_mode
{
    my ($mode) = @_;
    my %valid_modes = ("processed" => 1, "alpha" => 1, "id" => 1, 
                       "freq-asc" => 1, "freq-desc" => 1);
    return _validate_membership($mode, \%valid_modes, "Channel Sort Mode");
}

sub compare_channel_entries
{
    my ($a, $b, $sort_mode) = @_;

    my ($a_order, $a_name, $a_rx, $a_tx) = split("\t", $a);
    my ($b_order, $b_name, $b_rx, $b_tx) = split("\t", $b);

    if ($sort_mode eq "alpha") {
        return lc($a_name) cmp lc($b_name);
    }
    elsif ($sort_mode eq "id") {
        # The order prefix is already stored; compare it numerically
        return $a_order cmp $b_order;
    }
    elsif ($sort_mode eq "freq-asc") {
        return $a_rx <=> $b_rx;
    }
    elsif ($sort_mode eq "freq-desc") {
        return $b_rx <=> $a_rx;
    }
    else { # "processed" – keep original order
        return 0;  # presort will preserve input order
    }
}

####
# Validation Helpers
####

sub _validate_membership
{
    my ($value, $set_ref, $error) = @_;

    if (!$set_ref->{$value})
    {
        $error  = "Invalid $error: ";
        $error .= "'$value' is not one of: ";
        $error .= join(", ", keys %{$set_ref});
        $error .= _file_and_line();
        error($error);
    }

    return $value;
}

sub _validate_num_in_range
{
    my ($type, $value, $min, $max) = @_;

    if (!looks_like_number($value) || $value < $min || $value > $max)
    {
        error("Invalid $type: '$value' must be an number between $min and $max (inclusive)" . _file_and_line());
    }

    return $value;
}

sub _validate_on_off
{
    my ($value, $error) = @_;
    my %valid_on_off = ("On" => 1, "Off" => 1);
    
    return _validate_membership($value, \%valid_on_off, $error);
}

sub _validate_string_length
{
    my ($type, $string, $length) = @_;

    if(length($string) > $length)
    {
        error("Invalid $type: '$string' is more than $length characters" . _file_and_line());
    }

    return $string;
}

sub _file_and_line
{
    return " [On line #$global_line_number of $global_file_name file.]\n";
}



################################################################################
################################################################################
################################################################################
##########   GENERIC STUFF: usage(), command-line args, etc
################################################################################
################################################################################
################################################################################
sub handle_command_line_args
{
    my ($analog_filename, $digital_others_filename, $digital_repeaters_filename, $talkgroups_filename);
    my ($config_directory, $output_directory);

    GetOptions("analog-csv=s"             => \$analog_filename,
               "digital-others-csv=s"     => \$digital_others_filename,
               "digital-repeaters-csv=s"  => \$digital_repeaters_filename,
               "talkgroups-csv=s"         => \$talkgroups_filename,
               "config:s"                 => \$global_config_directory,
               "output-directory=s"       => \$output_directory,
               "sorting:s"                => \$global_sort_mode,
               "nicknames:s"              => \$global_nickname_mode,
               "hotspot-tx-permit:s"      => \$global_hotspot_tx_permit,
               "multi-zone!"              => \$global_multi_zone,
               "zone-channel-sort:s"      => \$global_zone_channel_sort,
               "scanlist-channel-sort:s"  => \$global_scanlist_channel_sort,
               "start-zone1=s"            => \$global_start_zone1,
               "start-zone2=s"            => \$global_start_zone2,
               "start-channel1=s"         => \$global_start_channel1,
               "start-channel2=s"         => \$global_start_channel2,
               "optional-settings-csv=s"  => \$global_optional_settings_filename,
               "json-mode!"               => \$global_json_mode)
        or usage();

    if (!defined($global_config_directory) || $global_config_directory eq '')
    {
        $global_config_directory = "config";
    }
    $config_directory = $global_config_directory;

    validate_sort_mode($global_sort_mode);
    if ($global_sort_mode eq "analog-first")
    {
        $zone_order_default = 0;
    }

    validate_hotspot_mode($global_hotspot_tx_permit);
    validate_nickname_mode($global_nickname_mode);
    validate_channel_sort_mode($global_zone_channel_sort);
    validate_channel_sort_mode($global_scanlist_channel_sort);

    # Validate startup options - all or nothing
    my $num_start_opts = count_startup_options();

    # If any startup option is provided, require all four
    if ($num_start_opts > 0 && $num_start_opts < 4) {
        error("If any --start-* option is specified, all four must be provided:\n"
            . "  --start-zone1, --start-zone2, --start-channel1, --start-channel2\n");
    }

    if (!$global_json_mode && (!defined($analog_filename) || !defined($digital_others_filename) || !defined($digital_repeaters_filename)
        || !defined($talkgroups_filename) || !defined($output_directory)))
    {
        usage();
    }

    return ($analog_filename, $digital_others_filename, $digital_repeaters_filename, $talkgroups_filename,
            $config_directory, $output_directory);
}


sub usage
{
    print "$0 \n";
    print "arguments:\n";
    print "  --analog-csv=<analog.csv>  \n";
    print "  --digital-others-csv=<digital-others.csv>\n";
    print "  --digital-repeaters-csv=<digital_repeaters.csv> \n";
    print "  --talkgroups-csv=<talkgroups.csv> \n";         
    print "  --output-directory=<output-directory>\n";
    print "  [--config=<config file>]\n";
    print "  [--sorting=(alpha|repeaters-first|analog-first)]\n";
    print "  [--hotspot-tx-permit=(always|same-color-code)]\n";
    print "  [--nicknames=(off|prefix|suffix)]\n";
    print "  [--multi-zone]             enable multiple zones/scanlists via '|' separator\n";
    print "  [--zone-channel-sort=(processed|alpha|id|freq-asc|freq-desc)]\n";
    print "  [--scanlist-channel-sort=(processed|alpha|id|freq-asc|freq-desc)]\n";
    print "  [--start-zone1=<zone>]     Zone for Receiver A\n";
    print "  [--start-zone2=<zone>]     Zone for Receiver B\n";
    print "  [--start-channel1=<chan>]  Channel for Receiver A\n";
    print "  [--start-channel2=<chan>]  Channel for Receiver B\n";
    print "        All four required together to enable startup channels.\n";
    print "  [--optional-settings-csv=<optional.csv>]  Template for full Optional Settings override\n";
    print "        (requires all --start-* options; generates both STUB and FULL)\n";
    exit -1;
}

sub error
{
    my ($error) = @_;

    print "ERROR: $error";
    exit -1;
}

sub warning
{
    my ($message) = @_;

    print "WARNING: $message\n";
}
