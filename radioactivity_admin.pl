#!/usr/bin/perl --
#!c:/perl/bin/perl.exe
use warnings;
use strict;
use HTML::Template;
use CGI;
use Date::Calc qw (:all);
use CGI::Carp qw(fatalsToBrowser);
use DBI;
use GD::Graph::linespoints;
use Data::Dumper;


my @allowed_users = qw (andrewss hadfield brewn);


#chdir ("D:/Templates/Radioactivity") or die "Can't move to Radioactivity templates dir: $!";
chdir ("/data/private/radioactivity/Radioactivity") or die "Can't move to Radioactivity templates dir: $!";

my $q = CGI -> new();

my $username;

unless (check_user()){
  exit;
}

my $dbh = DBI->connect("DBI:mysql:database=Radioactivity;host=localhost","cgiadmin","",
                       {RaiseError=>0,AutoCommit=>1});

unless ($dbh) {
  print_bug ("Couldn't connect to Radioactivity database: ".$DBI::errstr);
  exit;
}

my $action = $q -> param('action');

unless ($action) {
  show_options();
}
else {
  my %dispatch = (
		  incoming => \&incoming_display,

		  start_incoming => \&start_incoming,
		  edit_incoming => \&start_edit_incoming,
		  finish_edit_incoming => \&finish_edit_incoming,
		  finish_incoming => \&finish_incoming,
		  delete_incoming => \&delete_incoming,

		  outgoing => \&outgoing_display,

		  start_transfer => \&start_transfer,
		  finish_transfer => \&finish_transfer,
		  edit_transfer => \&start_edit_transfer,
		  finish_edit_transfer => \&finish_edit_transfer,
		  delete_transfer => \&delete_transfer,

		  start_liquid => \&start_liquid,
		  finish_liquid => \&finish_liquid,
		  edit_liquid => \&start_edit_liquid,
		  finish_edit_liquid => \&finish_edit_liquid,
		  delete_liquid => \&delete_liquid,

		  drums => \&drum_display,
		  show_drum => \&show_drum,
		  drum_collected => \&drum_collected,
		  new_drum => \&finish_new_drum,

		  reports => \&show_report_options,
		  'Monthly Report' => \&monthly_report,
		  'Annual Report' => \&annual_report,
		  'Usage Report' => \&usage_report,
		  graph => \&draw_usage_graph,

		  audits => \&audit_display,
		  delete_audit => \&delete_audit,
		  edit_audit => \&start_edit_audit,
		  finish_edit_audit => \&finish_edit_audit,
		  start_audit => \&start_audit,
		  finish_audit => \&finish_audit,

		  users => \&show_users,
		  start_edit_user => \&start_edit_user,
		  finish_edit_user => \&finish_edit_user,
		  list_new_users => \&add_new_user,
		  add_new_user => \&add_new_user_wrapper,
		 );

  unless (exists($dispatch{$action})){
    print_bug ("'$action' is an unknown action");
  }

  else {
    $dispatch{$action} -> ();
  }

}

sub show_options {
  my $template = HTML::Template->new(filename => 'admin_options.html');

  # Work out the current site holdings
  my $holdings;

  my $isotopes_sth = $dbh->prepare ("SELECT isotope_id,element,mw,half_life,site_holding_limit FROM Isotope ORDER BY mw");

  $isotopes_sth->execute() or do {
    print_bug("Couldn't list isotopes: ".$dbh->errstr());
    return;
  };

  while (my ($id,$element,$mw,$half_life,$site_limit)=$isotopes_sth -> fetchrow_array()){

    my $record;
    $record->{ISOTOPE} = "$mw $element";
    $record->{LIMIT} = $site_limit;

    my $current_activity = get_total_holding($id);
    unless (defined $current_activity) {
      return;
    }

    $record->{ACTIVITY} = sprintf("%.2f",$current_activity);
    $record->{USED} = sprintf("%.2f",($current_activity/$site_limit)*100);
    if ($record->{USED} > 100 or $record->{USED}<-1) {
      $record->{WARN}=1;
    }

    push @$holdings, $record;
  }

  $template -> param(HOLDINGS => $holdings);


  # Recent Incoming Data
  my $incoming_sth = $dbh->prepare("SELECT Isotope.element, Isotope.mw, Received.activity, Received.person_id, Received.input_person_id,Received.date FROM Received,Isotope WHERE Received.isotope_id=Isotope.isotope_id ORDER BY Received.date DESC LIMIT 5");
  $incoming_sth -> execute() or do {
    print_bug ("Couldn't list recent incoming samples: ".$dbh->errstr());
    return;
  };

  my @incoming;
  while (my ($element,$mw,$activity,$person_id,$input_person_id,$date) = $incoming_sth->fetchrow_array()){
    my ($first,$last,$phone) = get_user_details($person_id);
    my ($i_first,$i_last,$i_phone) = get_user_details($input_person_id);
    push @incoming , {ISOTOPE => "$mw $element",
		      ACTIVITY => $activity,
		      USER => "$first $last",
		      PHONE => $phone,
		      SUBMITTER => "$i_first $i_last",
		      DATE => $date};
  }

  $template -> param(INCOMING => \@incoming);


  # Recent Outgoing Solid Transfers
  my $transfer_out_sth = $dbh->prepare("SELECT Isotope.element, Isotope.mw, Transfer_disposal.activity, Transfer_disposal.person_id, Transfer_disposal.input_person_id,Transfer_disposal.date FROM Transfer_disposal,Isotope,Drum WHERE Transfer_disposal.isotope_id=Isotope.isotope_id AND Transfer_disposal.drum_id=Drum.drum_id AND Drum.material=\"solid\" ORDER BY Transfer_disposal.date DESC LIMIT 5");
  $transfer_out_sth -> execute() or do {
    print_bug ("Couldn't list recent solid waste disposals: ".$dbh->errstr());
    return;
  };

  my @solid_transfer;
  while (my ($element,$mw,$activity,$person_id,$input_person_id,$date) = $transfer_out_sth->fetchrow_array()){
    my ($first,$last,$phone) = get_user_details($person_id);
    my ($i_first,$i_last,$i_phone) = get_user_details($input_person_id);

    push @solid_transfer , {ISOTOPE => "$mw $element",
		       ACTIVITY => $activity,
		       USER => "$first $last",
		       PHONE => $phone,
		       SUBMITTER => "$i_first $i_last",
		       DATE => $date};
  }

  $template -> param(SOLID_TRANSFER => \@solid_transfer);

  # Recent Outgoing Liquid Transfers
  $transfer_out_sth = $dbh->prepare("SELECT Isotope.element, Isotope.mw, Transfer_disposal.activity, Transfer_disposal.person_id, Transfer_disposal.input_person_id,Transfer_disposal.date FROM Transfer_disposal,Isotope,Drum WHERE Transfer_disposal.isotope_id=Isotope.isotope_id AND Transfer_disposal.drum_id=Drum.drum_id AND Drum.material=\"liquid\" ORDER BY Transfer_disposal.date DESC LIMIT 5");
  $transfer_out_sth -> execute() or do {
    print_bug ("Couldn't list recent liquid waste transfers: ".$dbh->errstr());
    return;
  };

  my @liquid_transfer;
  while (my ($element,$mw,$activity,$person_id,$input_person_id,$date) = $transfer_out_sth->fetchrow_array()){
    my ($first,$last,$phone) = get_user_details($person_id);
    my ($i_first,$i_last,$i_phone) = get_user_details($input_person_id);

    push @liquid_transfer , {ISOTOPE => "$mw $element",
			     ACTIVITY => $activity,
			     USER => "$first $last",
			     PHONE => $phone,
			     SUBMITTER => "$i_first $i_last",
			     DATE => $date};
  }

  $template -> param(LIQUID_TRANSFER => \@liquid_transfer);


  # Recent Outgoing Liquid
  my $liquid_out_sth = $dbh->prepare("SELECT Isotope.element, Isotope.mw, Liquid_disposal.activity, Liquid_disposal.person_id, Liquid_disposal.input_person_id,Liquid_disposal.date FROM Liquid_disposal,Isotope WHERE Liquid_disposal.isotope_id=Isotope.isotope_id ORDER BY Liquid_disposal.date DESC LIMIT 5");
  $liquid_out_sth -> execute() or do {
    print_bug ("Couldn't list recent liquid waste disposals: ".$dbh->errstr());
    return;
  };

  my @liquid_out;
  while (my ($element,$mw,$activity,$person_id,$input_person_id,$date) = $liquid_out_sth->fetchrow_array()){
    my ($first,$last,$phone) = get_user_details($person_id);
    my ($i_first,$i_last,$i_phone) = get_user_details($input_person_id);
    push @liquid_out , {ISOTOPE => "$mw $element",
			ACTIVITY => $activity,
			USER => "$first $last",
			PHONE => $phone,
			SUBMITTER => "$i_first $i_last",
			DATE => $date};
  }

  $template -> param(LIQUID_OUT => \@liquid_out);



  print $template -> output();

}

sub show_report_options {
  my $template = HTML::Template->new(filename => 'report_options.html');
  print $template->output();
}


sub drum_display {

    my $template = HTML::Template->new(filename => 'drum_options.html');

    my $month = $q -> param("month");
    my $year = $q -> param("year");

    my ($current_year,$current_month,$current_day) = Today();

    unless ($month and $year) {
      # Use the current month
      $month = $current_month;
      $year = $current_year;
    }

    my @months;
    my $month_no = 1;
    foreach my $month_name (qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)) {
      my %month = (MONTH_NO => $month_no,
		   MONTH_NAME => $month_name);

      if ($month_no == $month) {
	$month{SELECTED} = 1;
      }
      push @months ,\%month;

      ++$month_no;
    }

    my @years;

    foreach my $year_name (2006..$current_year+1) {
      my %year = (YEAR => $year_name);
      if ($year_name == $year) {
	$year{SELECTED} = 1;
      }
      push @years, \%year;
    }

    $template -> param (MONTHS => \@months,
			YEARS => \@years,
		       );

    # This will be used to get the total count for all drums
    my $drum_sth = $dbh->prepare("SELECT Isotope.half_life, Transfer_disposal.activity, Transfer_disposal.date FROM Transfer_disposal, Isotope WHERE Transfer_disposal.drum_id=? AND Transfer_disposal.isotope_id=Isotope.isotope_id");

    # Get the active drum data
    my @active_drums;
    my $active_sth = $dbh->prepare("SELECT drum_id,date_started,material FROM Drum WHERE date_removed IS NULL ORDER BY date_started");
    $active_sth -> execute() or do {
      print_bug ("Couldn't list active drums: ".$dbh->errstr());
      return;
    };

    while (my ($id,$started,$material) = $active_sth -> fetchrow_array()) {

      # Now get the contents of the drum
      $drum_sth -> execute($id) or do {
	print_bug ("Couldn't list the contents of drum $id: ".$dbh->errstr());
	return;
      };

      my $total_activity = 0;

      while (my ($half_life,$activity,$date) = $drum_sth->fetchrow_array()) {

	my $corrected = corrected_activity($activity,$date,$half_life);
	return unless (defined $corrected);
	$total_activity += $corrected;

      }

      push @active_drums , {ID => $id,
			    ACTIVITY => sprintf("%.2f",$total_activity),
			    MATERIAL => $material,
			    CREATED => $started,
			    YEARS => get_years("$current_year-$current_month-$current_day"),
			    MONTHS => get_months("$current_year-$current_month-$current_day"),
			    DAYS => get_days("$current_year-$current_month-$current_day"),
			   };


    }

    $template->param(ACTIVE_DRUMS => \@active_drums);



    # Get the collected drum data
    my @collected_drums;
    my $from_date = "$year-$month-01";
    my $to_date = "$year-$month-".Days_in_Month($year,$month);
    my $collected_sth = $dbh->prepare("SELECT drum_id,date_started,date_removed,material FROM Drum WHERE date_removed IS NOT NULL AND date_removed>=? AND date_removed <=? ORDER BY date_removed");
    $collected_sth -> execute($from_date,$to_date) or do {
      print_bug ("Couldn't list collected drums: ".$dbh->errstr());
      return;
    };

    while (my ($id,$started,$removed,$material) = $collected_sth -> fetchrow_array()) {
      # Now get the contents of the drum

      $drum_sth -> execute($id) or do {
	print_bug ("Couldn't list the contents of drum $id: ".$dbh->errstr());
	return;
      };

      my $total_activity = 0;

      while (my ($half_life,$activity,$date) = $drum_sth->fetchrow_array()) {

	my $current_activity = corrected_activity($activity,$date,$half_life,$removed);
	return unless (defined $current_activity);
	$total_activity += $current_activity;

      }
	push @collected_drums , {ID => $id,
				 MATERIAL => $material,
				 ACTIVITY => sprintf("%.2f",$total_activity),
				 CREATED => $started,
				 COLLECTED => $removed,
				};

    }

    $template->param(COLLECTED_DRUMS => \@collected_drums);

    print $template->output();
}

sub show_drum {
  my $template = HTML::Template->new(filename => 'show_drum.html');

  my $id = $q -> param('id');

  unless ($id and $id=~/^\d+$/) {
    print_bug ("Drum id '$id' didn't look right");
    return;
  }

  # Get the basic information about the drum
  my ($db_id,$started,$removed,$material) = $dbh -> selectrow_array("SELECT drum_id,date_started,date_removed,material FROM Drum WHERE drum_id=?",undef,($id));

  unless ($db_id) {
    print_bug ("Error getting details for drum '$id':".$dbh->errstr());
    return;
  }

  $template -> param(ID => $id,
		     CREATED => $started,
		     COLLECTED => $removed,
		     MATERIAL => $material,
      );

  my $total_activity = 0;

  # Now get the contents of the drum
  my $drum_sth = $dbh->prepare("SELECT Isotope.element, Isotope.mw, Isotope.half_life, Transfer_disposal.activity, Person.first_name, Person.last_name, Building.number, Transfer_disposal.date FROM Transfer_disposal, Isotope, Person, Building WHERE Transfer_disposal.drum_id=? AND Transfer_disposal.isotope_id=Isotope.isotope_id AND Transfer_disposal.person_id=Person.person_id AND Transfer_disposal.building_id = Building.building_id ORDER BY Transfer_disposal.date");

  $drum_sth -> execute($id) or do {
    print_bug ("Couldn't list the contents of drum $id: ".$dbh->errstr());
    return;
  };

  my @records;

  # This var is used to keep a running total for each isotope for the summary
  my %summary;

  while (my ($element,$mw,$half_life,$activity,$first_name,$last_name,$building,$date) = $drum_sth->fetchrow_array()) {

    my $current_activity = corrected_activity($activity,$date,$half_life,$removed);
    $total_activity += $current_activity;

    push @records , {ISOTOPE => "$mw $element",
		     ORIG_ACTIVITY => $activity,
		     CURRENT_ACTIVITY => sprintf("%.2f",$current_activity),
		     USER => "$first_name $last_name",
		     BUILDING => $building,
		     DATE => $date,
		    };
    $summary{"$mw $element"} += $current_activity;
  }

  my @summary;
  foreach my $isotope (sort keys (%summary)) {
    push @summary, {ISOTOPE => $isotope,
		    ACTIVITY => sprintf("%.2f",$summary{$isotope})};
  }
  $template -> param(RECORDS => \@records,
		     ACTIVITY => sprintf("%.2f",$total_activity),
		     SUMMARY => \@summary);

  print $template->output();

}

sub drum_collected {
  my $id = $q -> param('id');
  my $month = $q->param('month');
  my $year = $q->param('year');

  my $collected_day = $q -> param("collected_day");
  my $collected_month = $q -> param("collected_month");
  my $collected_year = $q -> param("collected_year");

  unless (check_date($collected_year,$collected_month,$collected_day)) {
    print_error("$collected_year-$collected_month-$collected_day is not a vaild date");
    return;
  }

  my $date = "$collected_year-$collected_month-$collected_day";

  unless ($id and ($id=~/^\d+$/)){
    print_bug ("Drum id '$id' didn't look right when marking drum as collected");
    return;
  }

  # We need to check the collection date is after the last disposal
  # into this drum.

  my ($last_date) = $dbh->selectrow_array("SELECT date FROM Transfer_disposal WHERE drum_id=? ORDER BY date DESC LIMIT 1",undef,($id));

  unless ($last_date) {
    print_error("You can't collect a drum which doesn't have anything in it");
    return;
  }

  my ($last_year,$last_month,$last_day) = split(/-/,$last_date);

  if (Delta_Days($last_year,$last_month,$last_day,$collected_year,$collected_month,$collected_day)<0) {
    print_error("Your collection date must be after the last disposal into this drum ($last_year-$last_month-$last_day)");
    return;
  }

  $dbh -> do ("UPDATE Drum SET date_removed=? WHERE drum_id=?",undef,($date,$id)) or do {
    print_bug("Couldn't update Drum '$id' as collected: ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=drums&month=$month&year=$year");

}


sub finish_new_drum {

    my $type = $q->param("type");

    my $drum_type;
    if ($type eq 'solid') {
	$drum_type = 'solid';
    }
    elsif ($type eq 'liquid') {
	$drum_type = 'liquid';
    }
    else {
	print_bug("No or invalid drum type '$type' specified when creating a new drum");
	return;
    }

  $dbh -> do ("INSERT INTO Drum (date_started,material) VALUES (CURRENT_DATE(),?)",undef,($drum_type)) or do {
    print_bug("Couldn't create new drum: ".$dbh->errstr());
    return;
  };

  my ($id) = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");

  unless ($id) {
    print_bug ("Error getting id for new drum: ".$dbh->errstr());
    return;
  }

  my $template = HTML::Template->new(filename => 'finish_drum.html');
  $template -> param(ID => $id);

  print $template -> output();
}

sub incoming_display {

    my $template = HTML::Template->new(filename => 'incoming_options.html');

    my $month = $q -> param("month");
    my $year = $q -> param("year");

    my ($current_year,$current_month) = Today();

    unless ($month and $year) {
      # Use the current month
      $month = $current_month;
      $year = $current_year;
    }

    my @months;
    my $month_no = 1;
    foreach my $month_name (qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)) {
      my %month = (MONTH_NO => $month_no,
		   MONTH_NAME => $month_name);

      if ($month_no == $month) {
	$month{SELECTED} = 1;
      }
      push @months ,\%month;

      ++$month_no;
    }

    my @years;

    foreach my $year_name (2006..$current_year) {
      my %year = (YEAR => $year_name);
      if ($year_name == $year) {
	$year{SELECTED} = 1;
      }
      push @years, \%year;
    }

    my %order_options = (Date => 'Received.date',
			 Isotope => 'Isotope.mw',
			 Building => 'Building.number',
			 Activity => 'Received.activity',
			);

    my $order = $q->param("order");
    $order = 'Date' unless ($order);

    unless (exists ($order_options{$order})){
      print_bug("Invalid order option '$order'");
      return;
    }
    
    my @orders;

    foreach my $order_name (sort keys %order_options) {

      my %order = (ORDER_NAME => $order_name);

      if ($order_name eq $order) {
	$order{SELECTED} = 1;
      }

      push @orders,\%order;
    }

    $template -> param (MONTHS => \@months,
			YEARS => \@years,
			ORDERS => \@orders);


    # Now to get the actual data
    my $incoming_sth = $dbh -> prepare("SELECT Received.received_id,Isotope.element, Isotope.mw, Isotope.half_life, Received.activity, Received.product_code, Received.person_id,Received.input_person_id,Building.number, Received.date FROM Received,Isotope,Building WHERE Received.date >= ? AND Received.date < ? AND Received.isotope_id=Isotope.isotope_id AND Received.building_id=Building.building_id ORDER BY $order_options{$order}");
    my $from_date = "$year-$month-01";
    my $to_month = $month+1;
    my $to_year = $year;
    if ($to_month==13){
      $to_year++;
      $to_month = 1;
    }
    my $to_date = "$to_year-$to_month-01";
    $incoming_sth -> execute($from_date,$to_date) or do {
      print_bug ("Unable to list incoming radioactivity records: ".$dbh->errstr());
      return;
    };

    my @records;

    while (my ($id,$element,$mw,$half_life,$activity,$product_code,$person_id,$input_person_id,$building,$date) = $incoming_sth -> fetchrow_array()) {
      my $current_activity = corrected_activity ($activity,$date,$half_life);
      return unless (defined $current_activity);
      my ($first,$last) = get_user_details($person_id);
      my ($i_first,$i_last) = get_user_details($input_person_id);
      push @records, {ID => $id,
		      ISOTOPE => "$mw $element",
		      ORIG_ACTIVITY => $activity,
		      CURRENT_ACTIVITY => sprintf("%.2f",$current_activity),
		      STOCK_CODE => $product_code,
		      USER => "$first $last",
		      SUBMITTER => "$i_first $i_last",
		      BUILDING => $building,
		      DATE => $date,
		      ID => $id,
		      MONTH => $month,
		      YEAR => $year,
		      ORDER => $order,
		     };
    }

    $template -> param(RECORDS => \@records);
    print $template->output();
}

sub delete_incoming {

  my $id = $q -> param ("id");
  unless ($id) {
    print_bug ("No ID supplied when deleting incoming record");
    return;
  }

  my $month = $q -> param("month");
  my $year = $q->param("year");
  my $order = $q -> param("order");

  my ($db_id) = $dbh->selectrow_array("SELECT received_id FROM Received WHERE received_id=?",undef,($id));

  unless ($db_id) {
    print_bug("No received entry found with id '$id' when deleting");
    return;
  }

  $dbh->do("DELETE FROM Received WHERE received_id=?",undef,($id)) or do {
    print_bug ("Error deleting received record '$id': ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=incoming&month=$month&year=$year&order=$order");
}

sub delete_transfer {

  my $id = $q -> param ("id");
  unless ($id) {
    print_bug ("No ID supplied when deleting solid waste record");
    return;
  }

  my $month = $q -> param("month");
  my $year = $q->param("year");
  my $order = $q -> param("order");

  # If this solid waste was in a drum which has been collected
  # we can't let them delete it.
  my ($collected) = $dbh->selectrow_array("SELECT Drum.date_removed FROM Transfer_disposal,Drum WHERE Transfer_disposal.transfer_waste_id=? AND Transfer_disposal.drum_id=Drum.drum_id",undef,($id));

  if ($collected) {
    print_error("You can't delete this solid waste as it is in a drum which has been collected");
    return;
  }


  my ($db_id) = $dbh->selectrow_array("SELECT transfer_waste_id FROM Transfer_disposal WHERE transfer_waste_id=?",undef,($id));

  unless ($db_id) {
    print_bug("No solid waste entry found with id '$id' when deleting");
    return;
  }

  $dbh->do("DELETE FROM Transfer_disposal WHERE transfer_waste_id=?",undef,($id)) or do {
    print_bug ("Error deleting solid waste record '$id': ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=outgoing&month=$month&year=$year&order=$order");
}

sub delete_liquid {

  my $id = $q -> param ("id");
  unless ($id) {
    print_bug ("No ID supplied when deleting liquid waste record");
    return;
  }

  my $month = $q -> param("month");
  my $year = $q->param("year");
  my $order = $q -> param("order");

  my ($db_id) = $dbh->selectrow_array("SELECT liquid_waste_id FROM Liquid_disposal WHERE liquid_waste_id=?",undef,($id));

  unless ($db_id) {
    print_bug("No liquid waste entry found with id '$id' when deleting");
    return;
  }

  $dbh->do("DELETE FROM Liquid_disposal WHERE liquid_waste_id=?",undef,($id)) or do {
    print_bug ("Error deleting liquid waste record '$id': ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=outgoing&month=$month&year=$year&order=$order");
}

sub start_incoming {
  my $template = HTML::Template->new(filename => 'admin_start_incoming.html');

  my $buildings = get_buildings();
  return unless (defined $buildings);
  my $isotopes = get_isotopes();
  return unless (defined $isotopes);

  my ($year,$month,$day) = Today();
  my $date = "$year-$month-$day";

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      YEARS => get_years($date),
		      MONTHS => get_months($date),
		      DAYS => get_days($date),
		      USERS => get_users());

  print $template -> output();
}


sub start_edit_incoming {

  my $template = HTML::Template->new(filename => 'edit_incoming.html');

  my $id = $q -> param("id");
  unless ($id) {
    print_bug ("No ID supplied when editing incoming record");
    return;
  }

  my ($date,$isotope_id,$person_id,$building_id,$activity,$product_code) = $dbh->selectrow_array ("SELECT date,isotope_id,person_id,building_id,activity,product_code FROM Received WHERE received_id=?",undef,($id));

  unless ($date) {
    print_bug ("Couldn't get details for incoming record '$id' when editing: ".$dbh->errstr());
    return;
  }

  my $buildings = get_buildings($building_id);
  return unless (defined $buildings);
  my $isotopes = get_isotopes($isotope_id);
  return unless (defined $isotopes);

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      USERS => get_users($person_id),
		      YEARS => get_years($date),
		      DAYS => get_days($date),
		      MONTHS => get_months($date),
		      STOCK_CODE => $product_code,
		      ACTIVITY => $activity,
		      ID => $id,
		     );

  print $template -> output();
}



sub outgoing_display {

    my $template = HTML::Template->new(filename => 'outgoing_options.html');

    my $month = $q -> param("month");
    my $year = $q -> param("year");

    my ($current_year,$current_month) = Today();

    unless ($month and $year) {
      # Use the current month
      $month = $current_month;
      $year = $current_year;
    }

    my @months;
    my $month_no = 1;
    foreach my $month_name (qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)) {
      my %month = (MONTH_NO => $month_no,
		   MONTH_NAME => $month_name);

      if ($month_no == $month) {
	$month{SELECTED} = 1;
      }
      push @months ,\%month;

      ++$month_no;
    }

    my @years;

    foreach my $year_name (2006..$current_year) {
      my %year = (YEAR => $year_name);
      if ($year_name == $year) {
	$year{SELECTED} = 1;
      }
      push @years, \%year;
    }

    my %order_options = (Date => 'date',
			 Isotope => 'Isotope.mw',
			 Building => 'Building.number',
			 Activity => 'Received.activity',
			);

    my $order = $q->param("order");
    $order = 'Date' unless ($order);

    unless (exists ($order_options{$order})){
      print_bug("Invalid order option '$order'");
      return;
    }
    
    my @orders;

    foreach my $order_name (sort keys %order_options) {

      my %order = (ORDER_NAME => $order_name);

      if ($order_name eq $order) {
	$order{SELECTED} = 1;
      }

      push @orders,\%order;
    }

    $template -> param (MONTHS => \@months,
			YEARS => \@years,
			ORDERS => \@orders);

    my $order_option = $order_options{$order};
    if ($order_option eq 'date') {
      $order_option = 'Transfer_disposal.date';
    }

    # Now to get the solid transfer data
    my $solid_sth = $dbh -> prepare("SELECT Transfer_disposal.transfer_waste_id,Isotope.element, Isotope.mw, Isotope.half_life, Transfer_disposal.activity, Transfer_disposal.drum_id, Transfer_disposal.person_id,Transfer_disposal.input_person_id, Building.number, Transfer_disposal.date FROM Transfer_disposal,Isotope,Building,Drum WHERE Transfer_disposal.date >= ? AND Transfer_disposal.date < ? AND Transfer_disposal.isotope_id=Isotope.isotope_id AND Transfer_disposal.building_id=Building.building_id AND Transfer_disposal.drum_id=Drum.drum_id AND Drum.material=\"solid\" ORDER BY $order_option");
    my $from_date = "$year-$month-01";
    my $to_month = $month+1;
    my $to_year = $year;
    if ($to_month==13){
      $to_year++;
      $to_month = 1;
    }
    my $to_date = "$to_year-$to_month-01";
    $solid_sth -> execute($from_date,$to_date) or do {
      print_bug ("Unable to list solid waste radioactivity records: ".$dbh->errstr());
      return;
    };

    my @solid_records;

    while (my ($id,$element,$mw,$half_life,$activity,$drum_id,$person_id,$input_person_id,$building,$date) = $solid_sth -> fetchrow_array()) {
      my $current_activity = corrected_activity ($activity,$date,$half_life);
      return unless (defined $current_activity);
      my ($first,$last) = get_user_details($person_id);
      my ($i_first,$i_last) = get_user_details($input_person_id);
      push @solid_records, {ID => $id,
			    ISOTOPE => "$mw $element",
			    ORIG_ACTIVITY => $activity,
			    CURRENT_ACTIVITY => sprintf("%.2f",$current_activity),
			    DRUM_CODE => $drum_id,
			    USER => "$first $last",
			    SUBMITTER => "$i_first $i_last",
			    BUILDING => $building,
			    DATE => $date,
			    ID => $id,
			    MONTH => $month,
			    YEAR => $year,
			    ORDER => $order,
			   };
    }

    $template -> param(SOLID_TRANSFER_RECORDS => \@solid_records);


    # Now to get the liquid transfer data
    my $liquid_trans_sth = $dbh -> prepare("SELECT Transfer_disposal.transfer_waste_id,Isotope.element, Isotope.mw, Isotope.half_life, Transfer_disposal.activity, Transfer_disposal.drum_id, Transfer_disposal.person_id,Transfer_disposal.input_person_id, Building.number, Transfer_disposal.date FROM Transfer_disposal,Isotope,Building,Drum WHERE Transfer_disposal.date >= ? AND Transfer_disposal.date < ? AND Transfer_disposal.isotope_id=Isotope.isotope_id AND Transfer_disposal.building_id=Building.building_id AND Transfer_disposal.drum_id=Drum.drum_id AND Drum.material=\"liquid\" ORDER BY $order_option");

    $liquid_trans_sth -> execute($from_date,$to_date) or do {
      print_bug ("Unable to list liquid transfer waste radioactivity records: ".$dbh->errstr());
      return;
    };

    my @liquid_transfer_records;

    while (my ($id,$element,$mw,$half_life,$activity,$drum_id,$person_id,$input_person_id,$building,$date) = $liquid_trans_sth -> fetchrow_array()) {
      my $current_activity = corrected_activity ($activity,$date,$half_life);
      return unless (defined $current_activity);
      my ($first,$last) = get_user_details($person_id);
      my ($i_first,$i_last) = get_user_details($input_person_id);
      push @liquid_transfer_records, {ID => $id,
				      ISOTOPE => "$mw $element",
				      ORIG_ACTIVITY => $activity,
				      CURRENT_ACTIVITY => sprintf("%.2f",$current_activity),
				      DRUM_CODE => $drum_id,
				      USER => "$first $last",
				      SUBMITTER => "$i_first $i_last",
				      BUILDING => $building,
				      DATE => $date,
				      ID => $id,
				      MONTH => $month,
				      YEAR => $year,
				      ORDER => $order,
      };
    }

    $template -> param(LIQUID_TRANSFER_RECORDS => \@liquid_transfer_records);


    # Now to get the liquid disposal data

    $order_option = $order_options{$order};
    if ($order_option eq 'date') {
      $order_option = 'Liquid_disposal.date';
    }

    my $liquid_sth = $dbh -> prepare("SELECT Liquid_disposal.liquid_waste_id,Isotope.element, Isotope.mw, Isotope.half_life, Liquid_disposal.activity, Liquid_disposal.person_id, Liquid_disposal.input_person_id, Building.number, Liquid_disposal.date FROM Liquid_disposal,Isotope,Building WHERE Liquid_disposal.date >= ? AND Liquid_disposal.date < ? AND Liquid_disposal.isotope_id=Isotope.isotope_id AND Liquid_disposal.building_id=Building.building_id ORDER BY $order_option");
    $liquid_sth -> execute($from_date,$to_date) or do {
      print_bug ("Unable to list liquid waste radioactivity records: ".$dbh->errstr());
      return;
    };

    my @liquid_records;

    while (my ($id,$element,$mw,$half_life,$activity,$person_id,$input_person_id,$building,$date) = $liquid_sth -> fetchrow_array()) {
      my $current_activity = corrected_activity ($activity,$date,$half_life);
      return unless (defined $current_activity);
      my ($first,$last) = get_user_details($person_id);
      my ($i_first,$i_last) = get_user_details($input_person_id);

      push @liquid_records, {ID => $id,
			     ISOTOPE => "$mw $element",
			     ORIG_ACTIVITY => $activity,
			     CURRENT_ACTIVITY => sprintf("%.2f",$current_activity),
			     USER => "$first $last",
			     SUBMITTER => "$i_first $i_last",
			     BUILDING => $building,
			     DATE => $date,
			     ID => $id,
			     MONTH => $month,
			     YEAR => $year,
			     ORDER => $order,
			    };
    }

    $template -> param(LIQUID_RECORDS => \@liquid_records);



    print $template->output();
}

sub start_liquid {
  my $template = HTML::Template->new(filename => 'admin_start_liquid.html');

  my $buildings = get_buildings();
  return unless (defined $buildings);
  my $isotopes = get_isotopes();
  return unless (defined $isotopes);

  my ($year,$month,$day) = Today();
  my $date = "$year-$month-$day";

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      USERS => get_users(),
		      YEARS => get_years($date),
		      MONTHS => get_months($date),
		      DAYS => get_days($date));

  print $template -> output();
}

sub start_edit_liquid {

  my $template = HTML::Template->new(filename => 'edit_liquid.html');

  my $id = $q -> param("id");
  unless ($id) {
    print_bug ("No ID supplied when editing liquid waste record");
    return;
  }

  my ($date,$isotope_id,$building_id,$person_id,$activity) = $dbh->selectrow_array ("SELECT date,isotope_id,building_id,person_id,activity FROM Liquid_disposal WHERE liquid_waste_id=?",undef,($id));

  unless ($date) {
    print_bug ("Couldn't get details for liquid waste record '$id' when editing: ".$dbh->errstr());
    return;
  }

  my $buildings = get_buildings($building_id);
  return unless (defined $buildings);
  my $isotopes = get_isotopes($isotope_id);
  return unless (defined $isotopes);

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      USERS => get_users($person_id),
		      YEARS => get_years($date),
		      DAYS => get_days($date),
		      MONTHS => get_months($date),
		      ACTIVITY => $activity,
		      ID => $id,
		     );

  print $template -> output();
}


sub start_transfer {
  my $template = HTML::Template->new(filename => 'admin_start_solid.html');

  my $transfer_type = $q->param("type");

  my $buildings = get_buildings();
  return unless (defined $buildings);
  my $isotopes = get_isotopes();
  return unless (defined $isotopes);
  my $drums = get_active_drums($transfer_type);
  return unless (defined $drums);

  my ($year,$month,$day) = Today();
  my $date = "$year-$month-$day";

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      USERS => get_users(),
		      YEARS => get_years($date),
		      MONTHS => get_months($date),
		      DAYS => get_days($date),
		      DRUMS => $drums,
		      TYPE => $transfer_type,
     );

  print $template -> output();
}

sub start_edit_transfer {

  my $template = HTML::Template->new(filename => 'edit_solid.html');
  my $transfer_type = $q -> param("type");

  unless ($transfer_type eq 'solid' or $transfer_type eq 'liquid') {
      print_bug("Didn't understand drum type '$transfer_type' when editing a transfer");
      exit;
  }

  my $id = $q -> param("id");
  unless ($id) {
    print_bug ("No ID supplied when editing transfer waste record");
    return;
  }

  # If this solid waste was in a drum which has been collected
  # we can't let them edit it.
  my ($collected) = $dbh->selectrow_array("SELECT Drum.date_removed FROM Transfer_disposal,Drum WHERE Transfer_disposal.transfer_waste_id=? AND Transfer_disposal.drum_id=Drum.drum_id",undef,($id));

  if ($collected) {
    print_error("You can't edit this solid waste as it is in a drum which has been collected");
    return;
  }


  my ($date,$isotope_id,$person_id,$building_id,$activity,$drum_id) = $dbh->selectrow_array ("SELECT date,isotope_id,person_id,building_id,activity,drum_id FROM Transfer_disposal WHERE transfer_waste_id=?",undef,($id));

  unless ($date) {
    print_bug ("Couldn't get details for incoming record '$id' when editing: ".$dbh->errstr());
    return;
  }

  my $buildings = get_buildings($building_id);
  return unless (defined $buildings);
  my $isotopes = get_isotopes($isotope_id);
  return unless (defined $isotopes);
  my $drums = get_active_drums($transfer_type,$drum_id);
  return unless (defined $drums);

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      USERS => get_users($person_id),
		      YEARS => get_years($date),
		      DAYS => get_days($date),
		      MONTHS => get_months($date),
		      DRUMS => $drums,
		      ACTIVITY => $activity,
		      ID => $id,
		      TYPE => $transfer_type,
		     );

  print $template -> output();
}


sub finish_incoming {

  my $product_code = $q->param("supplier_code");
  unless ($product_code) {
    print_error("No product code was supplied");
    return;
  }

  my $user_id = $q->param("user_id");
  unless ($user_id) {
    print_error("No user was selected");
    return;
  }
  unless ($user_id =~ /^\d+$/) {
    print_bug ("User id '$user_id' didn't look right");
    return;
  }

  my $building_id = $q->param("building");
  unless ($building_id and $building_id =~ /^\d+$/) {
    print_bug ("Building id '$building_id' didn't look right");
    return;
  }

  my $isotope_id = $q->param("isotope");
  unless($isotope_id and $isotope_id =~ /^\d+$/) {
    print_bug("Isotope id '$isotope_id' didn't look right");
    return;
  }

  my ($isotope,$half_life) = get_isotope_from_id($isotope_id);

  my $activity = $q->param("activity");
  unless ($activity) {
    print_error("No activity value was supplied");
    return;
  }

  unless ($activity =~ /^\d+\.?\d*$/) {
    print_error("Activity value '$activity' was not a number");
    return;
  }

  if ($activity > 400) {
    print_error("Activity value $activity was > 400MBq which is suspiciously high.  Please contact your radioactivity safety rep");
    return;
  }

  my $date;

  my $day = $q->param("day");
  my $month = $q->param("month");
  my $year = $q->param("year");

  if (check_date($year,$month,$day)){
    $date = "$year-$month-$day";
  }
  else {
    print_error("$year(year)-$month(month)-$day(day) isn't a valid date");
    return;
  }

  if (Delta_Days(Today(),$year,$month,$day)>0){
    print_error("You can't create an entry with a date in the future");
    return;
  }

  # Get fully decayed date
  my $decayed_date = get_decayed_date($date,$activity,$half_life);
  return unless (defined $decayed_date);

  # Get a user id from the login credentials supplied
  my ($submitter_id) = check_valid_user($username);
  return unless ($submitter_id);

  # Finally we can create the new entry
  $dbh->do("INSERT INTO Received (date,isotope_id,person_id,input_person_id,building_id,product_code,activity,fully_decayed) VALUES (?,?,?,?,?,?,?,?)",undef,($date,$isotope_id,$user_id,$submitter_id,$building_id,$product_code,$activity,$decayed_date)) or do {
    print_bug ("Error inserting new incoming record: ".$dbh->errstr());
    return
  };

  # We can now get the new entry id
  my ($new_id) = $dbh->selectrow_array("SELECT LAST_INSERT_ID()");


  unless ($new_id) {
    print_bug ("Unable to get ID for newly inserted incoming record: ".$dbh->errstr());
    return;
  }

  my $template = HTML::Template->new(filename => 'admin_finish_incoming.html');

  $template->param(CODE => "RADIO$new_id",
		   ACTIVITY => $activity,
		   ISOTOPE => $isotope);

  # Now populate a new form so they can enter more data if they want:
  my $buildings = get_buildings();
  return unless (defined $buildings);
  my $isotopes = get_isotopes();
  return unless (defined $isotopes);

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      YEARS => get_years($date),
		      MONTHS => get_months($date),
		      DAYS => get_days($date),
		      USERS => get_users());

  print $template->output();

}


sub finish_edit_incoming {

  # Get a user id from the login credentials supplied
  my ($submitter_id) = check_valid_user($username);
  return unless ($submitter_id);


  my $id = $q->param("id");
  unless ($id and $id =~ /^\d+$/) {
    print_bug ("Invalid ID '$id' passed when finishing editing incoming entry");
    return;
  }

  my $product_code = $q->param("supplier_code");
  unless ($product_code) {
    print_error("No product code was supplied");
    return;
  }

  my $building_id = $q->param("building");
  unless ($building_id and $building_id =~ /^\d+$/) {
    print_bug ("Building id '$building_id' didn't look right");
    return;
  }

  my $user_id = $q->param("user_id");
  unless ($user_id) {
    print_error("No user was selected");
    return;
  }
  unless ($user_id =~ /^\d+$/) {
    print_bug ("User id '$user_id' didn't look right");
    return;
  }

  my $isotope_id = $q->param("isotope");
  unless($isotope_id and $isotope_id =~ /^\d+$/) {
    print_bug("Isotope id '$isotope_id' didn't look right");
    return;
  }

  my ($isotope,$half_life) = get_isotope_from_id($isotope_id);

  my $activity = $q->param("activity");
  unless ($activity) {
    print_error("No activity value was supplied");
    return;
  }

  unless ($activity =~ /^\d+\.?\d*$/) {
    print_error("Activity value '$activity' was not a number");
    return;
  }

  if ($activity > 400) {
    print_error("Activity value $activity was > 400MBq which is suspiciously high.  Please contact your radioactivity safety rep");
    return;
  }

  my $date;

  my $day = $q->param("day");
  my $month = $q->param("month");
  my $year = $q->param("year");

  if (check_date($year,$month,$day)){
    $date = "$year-$month-$day";
  }
  else {
    print_error("$year(year)-$month(month)-$day(day) isn't a valid date");
    return;
  }

  # Get fully decayed date
  my $decayed_date = get_decayed_date($date,$activity,$half_life);
  return unless (defined $decayed_date);

  # Finally we can update the entry
  $dbh->do("UPDATE Received SET date=?,isotope_id=?,building_id=?,person_id=?,input_person_id=?,product_code=?,activity=?,fully_decayed=? WHERE received_id=?",undef,($date,$isotope_id,$building_id,$user_id,$submitter_id,$product_code,$activity,$decayed_date,$id)) or do {
    print_bug ("Error updating incoming record: ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=incoming");
}


sub finish_transfer {

  my $drum_id = $q->param("drum");
  unless($drum_id and $drum_id =~ /^\d+$/) {
    print_bug("Drum id '$drum_id' didn't look right");
    return;
  }

  my $transfer_type = $q->param("type");
  unless ($transfer_type eq 'solid' or $transfer_type eq 'liquid') {
      print_bug("Didn't understand drum type '$transfer_type' when finishing a transfer");
      exit;
  }


  my $building_id = $q->param("building");
  unless ($building_id and $building_id =~ /^\d+$/) {
    print_bug ("Building id '$building_id' didn't look right");
    return;
  }

  my $user_id = $q->param("user_id");
  unless ($user_id) {
    print_error("No user was selected");
    return;
  }
  unless ($user_id =~ /^\d+$/) {
    print_bug ("User id '$user_id' didn't look right");
    return;
  }

  my $isotope_id = $q->param("isotope");
  unless($isotope_id and $isotope_id =~ /^\d+$/) {
    print_bug("Isotope id '$isotope_id' didn't look right");
    return;
  }

  my ($isotope,$half_life) = get_isotope_from_id($isotope_id);

  my $activity = $q->param("activity");
  unless ($activity) {
    print_error("No activity value was supplied");
    return;
  }

  unless ($activity =~ /^\d+\.?\d*$/) {
    print_error("Activity value '$activity' was not a number");
    return;
  }

  if ($activity > 400) {
    print_error("Activity value $activity was > 400MBq which is suspiciously high.  Please contact your radioactivity safety rep");
    return;
  }

  my $date;

  my $day = $q->param("day");
  my $month = $q->param("month");
  my $year = $q->param("year");

  if (check_date($year,$month,$day)){
    $date = "$year-$month-$day";
  }
  else {
    print_error("$year(year)-$month(month)-$day(day) isn't a valid date");
    return;
  }

  if (Delta_Days(Today(),$year,$month,$day)>0){
    print_error("You can't make a disposal with a date in the future");
    return;
  }

  # Get fully decayed date
  my $decayed_date = get_decayed_date($date,$activity,$half_life);
  return unless (defined $decayed_date);

  # Get a user id from the login credentials supplied
  my ($submitter_id) = check_valid_user($username);
  return unless ($submitter_id);

  # Finally we can create the new entry
  $dbh->do("INSERT INTO Transfer_disposal (date,isotope_id,person_id,input_person_id,building_id,drum_id,activity,fully_decayed) VALUES (?,?,?,?,?,?,?,?)",undef,($date,$isotope_id,$user_id,$submitter_id,$building_id,$drum_id,$activity,$decayed_date)) or do {
    print_bug ("Error inserting new solid_waste record: ".$dbh->errstr());
    return;
  };

  my $template = HTML::Template->new(filename => 'admin_finish_solid.html');

  $template->param(ACTIVITY => $activity,
		   ISOTOPE => $isotope);

  # Give them a new form to register another disposal
  my $buildings = get_buildings();
  return unless (defined $buildings);
  my $isotopes = get_isotopes();
  return unless (defined $isotopes);
  my $drums = get_active_drums($transfer_type);
  return unless (defined $drums);

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      USERS => get_users(),
		      YEARS => get_years($date),
		      MONTHS => get_months($date),
		      DAYS => get_days($date),
		      DRUMS => $drums,
		      TYPE => $transfer_type);

  print $template->output();

}


sub finish_edit_transfer {

  my $id = $q->param('id');
  unless ($id and $id =~ /^\d+$/) {
    print_bug ("Solid waste id '$id' didn't look right");
    return;
  }

  # If this solid waste was in a drum which has been collected
  # we can't let them edit it.
  my ($collected) = $dbh->selectrow_array("SELECT Drum.date_removed FROM Transfer_disposal,Drum WHERE Transfer_disposal.transfer_waste_id=? AND Transfer_disposal.drum_id=Drum.drum_id",undef,($id));

  if ($collected) {
    # This should have been caught by now, so it's a bug if it hasn't been.
    print_bug("You can't edit this solid waste as it is in a drum which has been collected");
    return;
  }

  my $drum_id = $q->param("drum");
  unless($drum_id and $drum_id =~ /^\d+$/) {
    print_bug("Drum id '$drum_id' didn't look right");
    return;
  }

  my $building_id = $q->param("building");
  unless ($building_id and $building_id =~ /^\d+$/) {
    print_bug ("Building id '$building_id' didn't look right");
    return;
  }

  my $user_id = $q->param("user_id");
  unless ($user_id) {
    print_error("No user was selected");
    return;
  }
  unless ($user_id =~ /^\d+$/) {
    print_bug ("User id '$user_id' didn't look right");
    return;
  }

  my $isotope_id = $q->param("isotope");
  unless($isotope_id and $isotope_id =~ /^\d+$/) {
    print_bug("Isotope id '$isotope_id' didn't look right");
    return;
  }

  my ($isotope,$half_life) = get_isotope_from_id($isotope_id);

  my $activity = $q->param("activity");
  unless ($activity) {
    print_error("No activity value was supplied");
    return;
  }

  unless ($activity =~ /^\d+\.?\d*$/) {
    print_error("Activity value '$activity' was not a number");
    return;
  }

  if ($activity > 400) {
    print_error("Activity value $activity was > 400MBq which is suspiciously high.  Please contact your radioactivity safety rep");
    return;
  }

  my $date;

  my $day = $q->param("day");
  my $month = $q->param("month");
  my $year = $q->param("year");

  if (check_date($year,$month,$day)){
    $date = "$year-$month-$day";
  }
  else {
    print_error("$year(year)-$month(month)-$day(day) isn't a valid date");
    return;
  }

  # Get fully decayed date
  my $decayed_date = get_decayed_date($date,$activity,$half_life);
  return unless (defined $decayed_date);

  # Get a user id from the login credentials supplied
  my ($submitter_id) = check_valid_user($username);
  return unless ($submitter_id);

  # Finally we can create the new entry
  $dbh->do("UPDATE Transfer_disposal SET date=?,isotope_id=?,building_id=?,person_id=?,input_person_id=?,drum_id=?,activity=?,fully_decayed=? WHERE transfer_waste_id=?",undef,($date,$isotope_id,$building_id,$user_id,$submitter_id,$drum_id,$activity,$decayed_date,$id)) or do {
    print_bug ("Error updating solid_waste record: ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=outgoing");

}

sub finish_liquid {

  my $building_id = $q->param("building");
  unless ($building_id and $building_id =~ /^\d+$/) {
    print_bug ("Building id '$building_id' didn't look right");
    return;
  }

  my $user_id = $q->param("user_id");
  unless ($user_id) {
    print_error("No user was selected");
    return;
  }
  unless ($user_id =~ /^\d+$/) {
    print_bug ("User id '$user_id' didn't look right");
    return;
  }

  my $isotope_id = $q->param("isotope");
  unless($isotope_id and $isotope_id =~ /^\d+$/) {
    print_bug("Isotope id '$isotope_id' didn't look right");
    return;
  }

  my ($isotope,$half_life) = get_isotope_from_id($isotope_id);

  my $activity = $q->param("activity");
  unless ($activity) {
    print_error("No activity value was supplied");
    return;
  }

  unless ($activity =~ /^\d+\.?\d*$/) {
    print_error("Activity value '$activity' was not a number");
    return;
  }

  if ($activity > 400) {
    print_error("Activity value $activity was > 400MBq which is suspiciously high.  Please contact your radioactivity safety rep");
    return;
  }

  my $date;

  my $day = $q->param("day");
  my $month = $q->param("month");
  my $year = $q->param("year");

  if (check_date($year,$month,$day)){
    $date = "$year-$month-$day";
  }
  else {
    print_error("$year(year)-$month(month)-$day(day) isn't a valid date");
    return;
  }

  if (Delta_Days(Today(),$year,$month,$day)>0){
    print_error("You can't make a disposal with a date in the future");
    return;
  }

  # Get fully decayed date
  my $decayed_date = get_decayed_date($date,$activity,$half_life);
  return unless (defined $decayed_date);

  # Get a user id from the login credentials supplied
  my ($submitter_id) = check_valid_user($username);
  return unless ($submitter_id);

  # Finally we can create the new entry
  $dbh->do("INSERT INTO Liquid_disposal (date,isotope_id,person_id,input_person_id,building_id,activity,fully_decayed) VALUES (?,?,?,?,?,?,?)",undef,($date,$isotope_id,$user_id,$submitter_id,$building_id,$activity,$decayed_date)) or do {
    print_bug ("Error inserting new liquid waste record: ".$dbh->errstr());
    return;
  };

  my $template = HTML::Template->new(filename => 'admin_finish_liquid.html');

  $template->param(ACTIVITY => $activity,
		   ISOTOPE => $isotope);

  # Set up another input form
  my $buildings = get_buildings();
  return unless (defined $buildings);
  my $isotopes = get_isotopes();
  return unless (defined $isotopes);

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      USERS => get_users(),
		      YEARS => get_years($date),
		      MONTHS => get_months($date),
		      DAYS => get_days($date));

  print $template->output();

}

sub finish_edit_liquid {

  my $id = $q->param('id');
  unless ($id and $id =~ /^\d+$/) {
    print_bug ("Solid waste id '$id' didn't look right");
    return;
  }


  my $building_id = $q->param("building");
  unless ($building_id and $building_id =~ /^\d+$/) {
    print_bug ("Building id '$building_id' didn't look right");
    return;
  }


  my $user_id = $q->param("user_id");
  unless ($user_id) {
    print_error("No user was selected");
    return;
  }
  unless ($user_id =~ /^\d+$/) {
    print_bug ("User id '$user_id' didn't look right");
    return;
  }

  my $isotope_id = $q->param("isotope");
  unless($isotope_id and $isotope_id =~ /^\d+$/) {
    print_bug("Isotope id '$isotope_id' didn't look right");
    return;
  }

  my ($isotope,$half_life) = get_isotope_from_id($isotope_id);

  my $activity = $q->param("activity");
  unless ($activity) {
    print_error("No activity value was supplied");
    return;
  }

  unless ($activity =~ /^\d+\.?\d*$/) {
    print_error("Activity value '$activity' was not a number");
    return;
  }

  if ($activity > 400) {
    print_error("Activity value $activity was > 400MBq which is suspiciously high.  Please contact your radioactivity safety rep");
    return;
  }

  my $date;

  my $day = $q->param("day");
  my $month = $q->param("month");
  my $year = $q->param("year");

  if (check_date($year,$month,$day)){
    $date = "$year-$month-$day";
  }
  else {
    print_error("$year(year)-$month(month)-$day(day) isn't a valid date");
    return;
  }

  # Get fully decayed date
  my $decayed_date = get_decayed_date($date,$activity,$half_life);
  return unless (defined $decayed_date);

  # Get a user id from the login credentials supplied
  my ($submitter_id) = check_valid_user($username);
  return unless ($user_id);

  # Finally we can create the new entry
  $dbh->do("UPDATE Liquid_disposal SET date=?,isotope_id=?,person_id=?,input_person_id=?,building_id=?,activity=?,fully_decayed=? WHERE liquid_waste_id=?",undef,($date,$isotope_id,$user_id,$submitter_id,$building_id,$activity,$decayed_date,$id)) or do {
    print_bug ("Error updating liquid_waste record: ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=outgoing");

}

sub monthly_report {
  my $template = HTML::Template->new(filename => 'monthly_report.html');

  my $month = $q -> param("month");
  my $year = $q -> param("year");

  my ($current_year,$current_month) = Today();

  unless ($month and $year) {
    # Use the current month
    $month = $current_month;
    $year = $current_year;
  }

  my $to_month = $month+1;
  my $to_year = $year;
  if ($to_month == 13) {
    ++$to_year;
    $to_month = 1;
  }

  my $to_date = "$to_year-$to_month-01";

  my @months;
  my $month_no = 1;
  foreach my $month_name (qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)) {
    my %month = (MONTH_NO => $month_no,
		 MONTH_NAME => $month_name);

    if ($month_no == $month) {
      $month{SELECTED} = 1;
    }
    push @months ,\%month;

    ++$month_no;
  }

  my @years;

  foreach my $year_name (2006..$current_year) {
    my %year = (YEAR => $year_name);
    if ($year_name == $year) {
      $year{SELECTED} = 1;
    }
    push @years, \%year;
  }

  $template -> param(MONTHS => \@months,
		     YEARS => \@years);


  # Step through all isotopes working out holdings and incoming/outgoing data
  my $records = [];

  my $isotopes_sth = $dbh->prepare ("SELECT isotope_id,element,mw,half_life,site_holding_limit,solid_monthly_disposal_limit,liquid_monthly_disposal_limit FROM Isotope ORDER BY mw");

  $isotopes_sth->execute() or do {
    print_bug("Couldn't list isotopes: ".$dbh->errstr());
    return;
  };

  while (my ($id,$element,$mw,$half_life,$site_limit,$solid_limit,$liquid_limit)=$isotopes_sth -> fetchrow_array()){

    my $record;
    $record->{ISOTOPE} = "$mw $element";

    my $current_activity = get_total_holding($id,$to_date);
    unless (defined $current_activity) {
      return;
    }

    $record->{TOTAL_HOLDING} = sprintf("%.2f",$current_activity);
    $record->{PERCENT_HOLDING} = sprintf("%.2f",($current_activity/$site_limit)*100);
    if ($record->{PERCENT_HOLDING} > 100 or $record->{PERCENT_HOLDING}<-1){
      $record->{WARN_HOLDING}=1;
    }

    # Now get the incoming and outgoing records for the month
    my ($total_incoming,$total_solid_transfer, $total_liquid_transfer,$total_liquid_disposal) = get_month_details($id,$year,$month);

    $record->{TOTAL_INCOMING} = $total_incoming;

    $record->{TOTAL_SOLID_TRANSFER} = $total_solid_transfer;
    $record->{PERCENT_SOLID_TRANSFER} = sprintf("%.2f",($total_solid_transfer/$solid_limit)*100);
    if ($record->{PERCENT_SOLID_TRANSFER} > 100 or $record->{PERCENT_SOLID_TRANSFER}<-1){
      $record->{WARN_SOLID_TRANSFER}=1;
    }


    $record->{TOTAL_LIQUID_TRANSFER} = $total_liquid_transfer;
    $record->{PERCENT_LIQUID_TRANSFER} = sprintf("%.2f",($total_liquid_transfer/$solid_limit)*100);
    if ($record->{PERCENT_LIQUID_TRANSFER} > 100 or $record->{PERCENT_LIQUID_TRANSFER}<-1){
      $record->{WARN_LIQUID_TRANSFER}=1;
    }

    $record->{TOTAL_LIQUID} = $total_liquid_disposal;
    $record->{PERCENT_LIQUID} = sprintf("%.2f",($total_liquid_disposal/$liquid_limit)*100);
    if ($record->{PERCENT_LIQUID} > 100 or $record->{PERCENT_LIQUID}<-1){
      $record->{WARN_LIQUID}=1;
    }

    # Don't show lines with no data in them
    next unless ($current_activity + $total_incoming + $total_solid_transfer + $total_liquid_transfer + $total_liquid_disposal > 0);

    push @$records, $record;
  }

  $template -> param(RECORDS => $records);

  print $template -> output();

}

sub annual_report {
  my $template = HTML::Template->new(filename => 'annual_report.html');

  my $year = $q -> param("year");

  my ($current_year) = Today();

  unless ($year) {
    $year = $current_year;
  }

  $template -> param(YEARS => get_years($year));

  my %isotope_classes;
  my %class_totals;

  my $get_isotopes_sth = $dbh->prepare("SELECT isotope_id,element,mw,emission_type FROM Isotope ORDER BY mw");
  $get_isotopes_sth -> execute() or do {
    print_bug("Couldn't list isotopes: ".$dbh->errstr());
    return;
  };

  while (my ($id,$element,$mw,$emission) = $get_isotopes_sth -> fetchrow_array()) {

    my $isotope;
    $isotope->{ISOTOPE} = "$mw $element";

    my $total_solid_transfer = 0;
    my $total_liquid_transfer = 0;
    my $total_liquid_disposal = 0;

    my @solid_transfer_data;
    my @liquid_transfer_data;
    my @liquid_disposal_data;

    foreach my $month (1..12) {
      my (undef,$solid_transfer,$liquid_transfer,$liquid_disposal) = get_month_details($id,$year,$month);

      push @solid_transfer_data, {VALUE => $solid_transfer};
      push @liquid_transfer_data, {VALUE => $liquid_transfer};
      push @liquid_disposal_data, {VALUE => $liquid_disposal};
      $total_solid_transfer += $solid_transfer;
      $class_totals{$emission}->{solid_transfer}->[$month-1] += $solid_transfer;
      $total_liquid_transfer += $liquid_transfer;
      $class_totals{$emission}->{liquid_transfer}->[$month-1] += $liquid_transfer;
      $total_liquid_disposal += $liquid_disposal;
      $class_totals{$emission}->{liquid_disposal}->[$month-1] += $liquid_disposal;
    }

    $isotope->{SOLID_TRANSFER_DATA} = \@solid_transfer_data;
    $isotope->{LIQUID_TRANSFER_DATA} = \@liquid_transfer_data;
    $isotope->{LIQUID_DISPOSAL_DATA} = \@liquid_disposal_data;
    $isotope->{SOLID_TRANSFER_TOTAL} = $total_solid_transfer;
    $isotope->{LIQUID_TRANSFER_TOTAL} = $total_liquid_transfer;
    $isotope->{LIQUID_DISPOSAL_TOTAL} = $total_liquid_disposal;

    # Skip isotopes which have nothing to report
    next unless ($total_solid_transfer + $total_liquid_transfer + $total_liquid_disposal > 0);

    push @{$isotope_classes{$emission}}, $isotope;

  }

  my @isotope_classes;

  foreach my $class (sort keys %isotope_classes){
    push @isotope_classes, {NO_MEMBERS => scalar @{$isotope_classes{$class}} *3,
			    ISOTOPE_TYPE => $class,
			    ISOTOPES => $isotope_classes{$class}};
  }

#  print "Content-type: text/plain\n\n";
#  print Dumper \@isotope_classes;
#  return;

  $template -> param(ISOTOPE_CLASSES => \@isotope_classes);

  my @type_totals;

  foreach my $class (sort keys %class_totals) {
    my @solid_transfer_data;
    my @liquid_transfer_data;
    my @liquid_disposal_data;
    my $solid_transfer_total = 0;
    my $liquid_transfer_total = 0;
    my $liquid_disposal_total = 0;

    foreach (@{$class_totals{$class}->{solid_transfer}}) {
      push @solid_transfer_data, {VALUE => $_};
      $solid_transfer_total += $_;
    }

    foreach (@{$class_totals{$class}->{liquid_transfer}}) {
      push @liquid_transfer_data, {VALUE => $_};
      $liquid_transfer_total += $_;
    }

    foreach (@{$class_totals{$class}->{liquid_disposal}}) {
      push @liquid_disposal_data, {VALUE => $_};
      $liquid_disposal_total += $_;
    }

    push @type_totals , {
			 ISOTOPE_TYPE => $class,
			 SOLID_TRANSFER_DATA => \@solid_transfer_data,
			 LIQUID_TRANSFER_DATA => \@liquid_transfer_data,
			 LIQUID_DISPOSAL_DATA => \@liquid_disposal_data,
			 SOLID_TRANSFER_TOTAL => $solid_transfer_total,
			 LIQUID_TRANSFER_TOTAL => $liquid_transfer_total,
			 LIQUID_DISPOSAL_TOTAL => $liquid_disposal_total,
			};
  }

  $template -> param(TYPE_TOTALS => \@type_totals);

  print $template->output();

}

sub usage_report {
  my $from_month = $q->param('fm');
  my $to_month = $q->param('tm');

  my $from_year = $q->param('fy');
  my $to_year = $q->param('ty');

  my @isotopes = $q->param('i');

  my $selected_type = $q -> param('t');

  my $selected_measure = $q -> param('m');

  if ($from_month) {
    unless (Delta_Days($from_year,$from_month,1,$to_year,$to_month,01) > 0) {
      print_error("Your 'to' date was the same or earlier than your 'from' date");
      return;
    }
    unless (scalar @isotopes) {
      print_error("No isotopes were selected");
      return;
    }
  }

  if ($selected_type and $selected_measure and ($selected_type eq 'i') and ($selected_measure eq 'p')) {
    print_error("Can't draw a %limit graph for incoming material as this doesn't have a limit set");
    return;
  }


  my $template = HTML::Template->new(filename => 'usage_report.html');

  my @types = (
	       {NAME => 'Holdings', VALUE => 'h', SELECTED => 0},
	       {NAME => 'Incoming', VALUE => 'i', SELECTED => 0},
	       {NAME => 'Solid Transfer Waste', VALUE => 's', SELECTED => 0},
	       {NAME => 'Liquid Transfer Waste', VALUE => 'q', SELECTED => 0},
	       {NAME => 'Liquid Disposal Waste', VALUE => 'l', SELECTED => 0},
	      );

  foreach my $type (@types) {
    if ($type->{VALUE} eq $selected_type) {
      $type->{SELECTED} = 1;
    }
  }

  my @measures = (
		  {NAME => '% limit', VALUE => 'p', SELECTED => 0},
		  {NAME => 'Absolute', VALUE => 'a', SELECTED => 0},
		 );

  foreach my $measure (@measures) {
    if ($measure->{VALUE} eq $selected_measure) {
      $measure->{SELECTED} = 1;
    }
  }

  my $from_months = get_months("$from_year-$from_month");
  my $from_years = get_years($from_year);
  my $to_months = get_months("$to_year-$to_month");
  my $to_years = get_years ($to_year);

  my $isotopes = get_isotopes(@isotopes);

  $template -> param(FROM_MONTHS => $from_months,
		     FROM_YEARS => $from_years,
		     TO_MONTHS => $to_months,
		     TO_YEARS => $to_years,
		     ISOTOPES => $isotopes,
		     FROM_MONTH => $from_month,
		     TO_MONTH => $to_month,
		     FROM_YEAR => $from_year,
		     TO_YEAR => $to_year,
		     TYPES => \@types,
		     TYPE => $selected_type,
		     MEASURES => \@measures,
		     MEASURE => $selected_measure,
		    );

  if ($isotopes[0]) {
    my @isotope_ids;
    push @isotope_ids , {ID => $_} foreach (@isotopes);
    $template -> param(GRAPH => 1,
		       ISOTOPE_IDS => \@isotope_ids);
  }

  print $template -> output();

}

sub draw_usage_graph {
  my $from_month = $q->param('fm');
  my $to_month = $q->param('tm');

  my $from_year = $q->param('fy');
  my $to_year = $q->param('ty');

  my @isotopes = $q->param('i');

  my $type = $q->param('t');

  my $measure = $q->param('m');

  # No point sending errors here as we're expected to return an image
  unless ($from_month and $to_month and $from_year and $to_year and $type and $measure and scalar @isotopes) {
    warn "No enough data to draw a graph '$from_month' '$to_month' '$from_year' '$to_year' '$type' ".scalar @isotopes;
    return;
  }

  my @isotope_names;
  my %isotope_limits;
  my $isotope_sth = $dbh->prepare("SELECT element,mw,site_holding_limit,solid_monthly_disposal_limit,liquid_monthly_disposal_limit FROM Isotope WHERE isotope_id=?");

  foreach (@isotopes) {
    $isotope_sth->execute($_) or die "Can't get isotope name for $_: ".$dbh->errstr();
    my ($e,$m,$h,$s,$l) = $isotope_sth->fetchrow_array();
    push @isotope_names ,"$m$e";
    if ($measure eq 'p') {
      # We're using a relative measure so we need to populate the limits data structure
      if ($type eq 'h') {
	$isotope_limits{$_} = $h;
      }
      elsif ($type eq 's') {
	$isotope_limits{$_} = $s;
      }
      elsif ($type eq 'q') {
	$isotope_limits{$_} = $s;
      }
      elsif ($type eq 'l') {
	$isotope_limits{$_} = $l;
      }
      else {
	die "Didn't recognise graph type '$type'";
      }
    }
  }



  my @months;

  while (1) {
#    warn "Adding month $from_month-$from_year\n";
    push @months, "$from_month-$from_year";
    last if (($from_month == $to_month) and ($from_year == $to_year));
    ++$from_month;
    if ($from_month == 13) {
      ++$from_year;
      $from_month = 1;
    }

  }

  my @data;
  push @data , \@months;
  foreach my $isotope (@isotopes) {

    my @isotope_data;

    foreach my $month (@months) {
      my ($m,$y) = split(/\-/,$month);
      ++$m;
      if ($m == 13) {
	++$y;
	$m=1;
      }
      if ($type eq 'h') {
	if ($measure eq 'a') {
	  push @isotope_data, get_total_holding($isotope,"$y-$m-01");
	}
	else {
	  push @isotope_data, (get_total_holding($isotope,"$y-$m-01")/$isotope_limits{$isotope})*100;
	}
      }
      elsif ($type eq 'i') {
	push @isotope_data, (get_month_details($isotope,$y,$m))[0];
      }
      elsif ($type eq 's') {
	if ($measure eq 'a') {
	  push @isotope_data, (get_month_details($isotope,$y,$m))[1];
	}
	else {
	  push @isotope_data, ((get_month_details($isotope,$y,$m))[1]/$isotope_limits{$isotope})*100;
	}
      }
      elsif ($type eq 'q') {
	if ($measure eq 'a') {
	  push @isotope_data, (get_month_details($isotope,$y,$m))[2];
	}
	else {
	  push @isotope_data, ((get_month_details($isotope,$y,$m))[2]/$isotope_limits{$isotope})*100;
	}
      }
      elsif ($type eq 'l') {
	if ($measure eq 'a') {
	  push @isotope_data, (get_month_details($isotope,$y,$m))[3];
	}
	else {
	  push @isotope_data, ((get_month_details($isotope,$y,$m))[3]/$isotope_limits{$isotope})*100;
	}
      }
      else {
	die "Didn't recognise graph type '$type'";
      }
    }
    push @data, \@isotope_data;
  }

  my $y_label = 'Activity (MBq)';
  if ($measure eq 'p') {
    $y_label = '% site limit';
  }

  my $graph = GD::Graph::linespoints-> new (640,480);
  $graph -> set (
		 x_label => 'Months',
		 x_label_position => 0.5,
		 y_label => $y_label,
		) or die "Error setting graph options: ".$graph->error();


  $graph -> set_legend(@isotope_names);

  binmode STDOUT;
  print "Content-type: image/png\n\n";

  print $graph->plot(\@data)->png();

}

sub audit_display {

    my $template = HTML::Template->new(filename => 'audit_options.html');

    my $month = $q -> param("month");
    my $year = $q -> param("year");

    my ($current_year,$current_month) = Today();

    unless ($month and $year) {
      # Use the current month
      $month = $current_month;
      $year = $current_year;
    }

    my $base_date = "$year-$month-".Days_in_Month($year,$month); # Use the last day of the month

    my @months;
    my $month_no = 1;
    foreach my $month_name (qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)) {
      my %month = (MONTH_NO => $month_no,
		   MONTH_NAME => $month_name);

      if ($month_no == $month) {
	$month{SELECTED} = 1;
      }
      push @months ,\%month;

      ++$month_no;
    }

    my @years;

    foreach my $year_name (2006..$current_year) {
      my %year = (YEAR => $year_name);
      if ($year_name == $year) {
	$year{SELECTED} = 1;
      }
      push @years, \%year;
    }

    my %order_options = (Date => 'Received.date',
			 Isotope => 'Isotope.mw',
			 Building => 'Building.number',
			 Activity => 'Received.activity',
			);

    my $order = $q->param("order");
    $order = 'Date' unless ($order);

    unless (exists ($order_options{$order})){
      print_bug("Invalid order option '$order'");
      return;
    }

    $template -> param (MONTHS => \@months,
			YEARS => \@years,
		       );


    # Now we loop through the buildings
    my @buildings;
    my $buildings_sth = $dbh->prepare("SELECT building_id, number from Building ORDER BY number");

    $buildings_sth -> execute() or do {
      print_bug ("Couldn't list buildings: ".$dbh->errstr());
      return;
    };

    # Get a list of the isotopes we're going to use
    my $isotopes_sth = $dbh->prepare("SELECT isotope_id,element,mw FROM Isotope ORDER BY mw");
    $isotopes_sth -> execute() or do {
      print_bug ("Couldn't list isotopes: ".$dbh->errstr());
      return;
    };

    my @isotopes;
    while (my ($isotope_id,$element,$mw) = $isotopes_sth -> fetchrow_array()) {
      push @isotopes , {
			id => $isotope_id,
			name => "$mw $element",
		       };
    }

    # Prepare the audit sth we're going to use several times
    my $last_audit_sth = $dbh->prepare("SELECT audit_id,date,activity FROM Audit WHERE date <=? AND isotope_id=? AND building_id=? ORDER BY date DESC LIMIT 1");


    @buildings = ();
    while (my ($building_id, $building_no) = $buildings_sth ->fetchrow_array()) {

      my $building = {BUILDING_NAME => $building_no};

      my @audits;
      foreach my $isotope (@isotopes) {
	$last_audit_sth -> execute($base_date,$isotope->{id},$building_id) or do {
	  print_bug ("Couldn't get last audit before $base_date for isotope ".$isotope->{id}." and building $building_id: ".$dbh->errstr());
	  return;
	};
	my ($audit_id,$date,$activity) = $last_audit_sth -> fetchrow_array();

	if ($audit_id) {
	  push @audits , {
			  ID => $audit_id,
			  ISOTOPE => $isotope->{name},
			  ACTIVITY => $activity,
			  DATE => $date,
			  MONTH => $month,
			  YEAR => $year,
			 };
	}
	else {
	  push @audits , {
			  ISOTOPE => $isotope->{name},
			  ACTIVITY => "-",
			  DATE => "-",
			  MONTH => $month,
			  YEAR => $year,
			 };

	}
      }
      $building -> {AUDITS}  = \@audits;
      push @buildings, $building;
    }


    $template -> param(BUILDINGS => \@buildings);
    print $template->output();
}

sub delete_audit {

  my $id = $q -> param ("id");
  unless ($id) {
    print_bug ("No ID supplied when deleting audit");
    return;
  }

  my $month = $q -> param("month");
  my $year = $q->param("year");

  my ($db_id) = $dbh->selectrow_array("SELECT audit_id FROM Audit WHERE audit_id=?",undef,($id));

  unless ($db_id) {
    print_bug("No audit found with id '$id' when deleting");
    return;
  }

  $dbh->do("DELETE FROM Audit WHERE audit_id=?",undef,($id)) or do {
    print_bug ("Error deleting audit '$id': ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=audits&month=$month&year=$year");
}

sub start_edit_audit {

  my $template = HTML::Template->new(filename => 'edit_audit.html');

  my $id = $q -> param("id");
  unless ($id) {
    print_bug ("No ID supplied when editing audit");
    return;
  }

  my ($date,$isotope_id,$building_id,$activity) = $dbh->selectrow_array ("SELECT date,isotope_id,building_id,activity FROM Audit WHERE audit_id=?",undef,($id));

  unless ($date) {
    print_bug ("Couldn't get details for audit '$id' when editing: ".$dbh->errstr());
    return;
  }

  my $buildings = get_buildings($building_id);
  return unless (defined $buildings);
  my $isotopes = get_isotopes($isotope_id);
  return unless (defined $isotopes);

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      YEARS => get_years($date),
		      DAYS => get_days($date),
		      MONTHS => get_months($date),
		      ACTIVITY => $activity,
		      ID => $id,
		     );

  print $template -> output();
}

sub finish_edit_audit {

  my $id = $q->param("id");
  unless ($id and $id =~ /^\d+$/) {
    print_bug ("Invalid ID '$id' passed when finishing editing audit");
    return;
  }

  my $building_id = $q->param("building");
  unless ($building_id and $building_id =~ /^\d+$/) {
    print_bug ("Building id '$building_id' didn't look right");
    return;
  }

  my $isotope_id = $q->param("isotope");
  unless($isotope_id and $isotope_id =~ /^\d+$/) {
    print_bug("Isotope id '$isotope_id' didn't look right");
    return;
  }

  my $activity = $q->param("activity");
  unless ($activity) {
    print_error("No activity value was supplied");
    return;
  }

  unless ($activity =~ /^\d+\.?\d*$/) {
    print_error("Activity value '$activity' was not a number");
    return;
  }

  if ($activity > 400) {
    print_error("Activity value $activity was > 400MBq which is suspiciously high.  Please contact your radioactivity safety rep");
    return;
  }

  my $date;

  if ($q->param("date_type") eq 'today') {
    my ($year,$month,$day) = Today();
    $date = "$year-$month-$day";
  }
  elsif ($q->param("date_type") eq 'other'){
    my $day = $q->param("day");
    my $month = $q->param("month");
    my $year = $q->param("year");

    if (check_date($year,$month,$day)){
      $date = "$year-$month-$day";
    }
    else {
      print_error("$year(year)-$month(month)-$day(day) isn't a valid date");
      return;
    }
  }


  # Finally we can update the entry
  $dbh->do("UPDATE Audit SET date=?,isotope_id=?,building_id=?,activity=? WHERE audit_id=?",undef,($date,$isotope_id,$building_id,$activity,$id)) or do {
    print_bug ("Error updating audit record: ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=audits");
}


sub start_audit {
  my $template = HTML::Template->new(filename => 'start_audit.html');

  my $buildings = get_buildings();
  return unless (defined $buildings);
  my $isotopes = get_isotopes();
  return unless (defined $isotopes);

  $template -> param (BUILDINGS => $buildings,
		      ISOTOPES => $isotopes,
		      YEARS => get_years());

  print $template -> output();
}

sub finish_audit {

  my $building_id = $q->param("building");
  unless ($building_id and $building_id =~ /^\d+$/) {
    print_bug ("Building id '$building_id' didn't look right");
    return;
  }

  my $date;

  if ($q->param("date_type") eq 'today') {
    my ($year,$month,$day) = Today();
    $date = "$year-$month-$day";
  }
  elsif ($q->param("date_type") eq 'other'){
    my $day = $q->param("day");
    my $month = $q->param("month");
    my $year = $q->param("year");

    if (check_date($year,$month,$day)){
      $date = "$year-$month-$day";
    }
    else {
      print_error("$year(year)-$month(month)-$day(day) isn't a valid date");
      return;
    }
  }

  my %audit_data;

  my @all_params = $q -> param();

  foreach my $param(@all_params) {
    if ($param =~ /isotope_(\d+)/) {
      my $id = $1;
      my $value = $q -> param($param);
      if (defined $value and length $value) {
	unless ($value =~ /^\d+\.?\d*$/) {
	  print_error ("Activity value '$value' was not a number for $param");
	  return;
	}
	$audit_data{$id} = $value;
      }
    }
  }

  my $audit_sth = $dbh->prepare("INSERT INTO Audit (building_id,date,isotope_id,activity) VALUES (?,?,?,?)");

  foreach my $id (keys %audit_data) {
    $audit_sth -> execute($building_id,$date,$id,$audit_data{$id}) or do {
      print_bug ("Error inserting new audit data: ".$dbh->errstr());
      return;
    }
  }

  print $q->redirect("radioactivity_admin.pl?action=audits");
}


sub show_users {
  my $template = HTML::Template->new(filename => 'show_users.html');

  my $offset = $q -> param('offset');

  $offset = 0 unless ($offset);

  # Get all users details
  my $users_sth = $dbh -> prepare("SELECT person_id,first_name,last_name, email, phone, active FROM Person ORDER BY last_name");

  $users_sth -> execute() or do {
    print_bug ("Couldn't get list of users: ".$dbh-> errstr());
    return;
  };

  my $users = $users_sth -> fetchall_arrayref();

  # We allow 20 users per screen, but need to find the break points
  my @categories;

  my $current_point = 0;
  while ($current_point <= scalar @$users) {
    my $last_point = $current_point + 19;
    $last_point = scalar @$users - 1 if ($last_point >= scalar @$users);
    push @categories, {START => lc($users->[$current_point]->[2]),
		       END => lc($users->[$last_point]->[2]),
		       OFFSET => $current_point};
    $current_point += 20;
  }

  my @users;

  for ($offset .. $offset+19) {
    last if $_ == scalar @$users;
    push @users, {
		  ID => $users->[$_]->[0],
		  FIRST_NAME => $users->[$_]->[1],
		  LAST_NAME => $users->[$_]->[2],
		  EMAIL => $users->[$_]->[3],
		  PHONE => $users->[$_]->[4],
		  ACTIVE => $users->[$_]->[5],
		 };
  }

  $template -> param(
		     USERS => \@users,
		     CATEGORIES => \@categories,
		    );
  print $template->output();

}

sub start_edit_user {

  my ($id) = $q -> param('id');

  unless ($id and ($id =~ /^\d+$/)) {
    print_bug ("Invalid user id '$id' passed when editing user");
    return;
  }

  my ($db_id,$first_name,$last_name,$email,$phone,$active)= $dbh->selectrow_array("SELECT person_id,first_name,last_name,email,phone,active FROM Person WHERE person_id=?",undef,($id));

  unless ($db_id) {
    print_bug ("Couldn't find user '$id' in the database when editing: ".$dbh->errstr());
    return;
  }

  my $template = HTML::Template->new(filename => 'edit_user.html');

  $template -> param(
		     ID => $id,
		     FIRST_NAME => $first_name,
		     LAST_NAME => $last_name,
		     PHONE => $phone,
		     EMAIL => $email,
		     ACTIVE => $active,
		    );

  print $template -> output();


}

sub finish_edit_user {

  my ($id) = $q -> param('id');

  unless ($id and ($id =~ /^\d+$/)) {
    print_bug ("Invalid user id '$id' passed when editing user");
    return;
  }

  my $first_name = $q->param("first_name");
  unless ($first_name) {
    print_error("No first name supplied");
    return;
  }

  my $last_name = $q->param("last_name");
  unless ($last_name) {
    print_error("No last name supplied");
    return;
  }

  my $phone = $q->param("phone");
  unless ($phone) {
    print_error("No phone number supplied");
    return;
  }

  my $email = $q->param("email");
  unless ($email) {
    print_error("No email supplied");
    return;
  }

  my $active = $q->param("active");
  if ($active) {
      $active = 1;
  }
  else {
      $active = 0;
  }

  $dbh->do("UPDATE Person SET first_name=?,last_name=?,phone=?,email=?,active=? WHERE person_id=?",undef,($first_name,$last_name,$phone,$email,$active,$id)) or do {
    print_bug ("Error updating person '$id': ".$dbh->errstr());
    return;
  };

  print $q->redirect("radioactivity_admin.pl?action=users");


}

sub add_new_user {


  if ($q -> param("submit")) {

      # We're going to actually add something
    
      # Check that they've supplied everything they need to
      my $username = $q->param("username");
      my $first_name = $q->param("first_name");
      my $last_name = $q->param("last_name");
      my $email = $q->param("email");

      unless ($username) {
	  print_error("No username supplied");
	  return;
      }
      unless ($first_name) {
	  print_error("No first name supplied");
	  return;
      }
      unless ($last_name) {
	  print_error("No last name supplied");
	  return;
      }
      unless ($email) {
	  print_error("No email supplied");
	  return;
      }

      # Check that this user doesn't already exist
      my ($found) = $dbh->selectrow_array("SELECT person_id FROM Person WHERE username=?",undef,($username));

      if ($found) {
	  print_error("There is already a user with the username $username");
	  return;
      }

      ($found) = $dbh->selectrow_array("SELECT person_id FROM Person WHERE email=?",undef,($email));

      if ($found) {
	  print_error("There is already a user with the email $email");
	  return;
      }

      $dbh -> do("INSERT INTO Person (username,first_name,last_name,email,phone,active) VALUES (?,?,?,?,?,?)",undef, ($username,$first_name,$last_name,$email,"x6000",1)) or do {
	  print_bug("Error adding $username to the system: ".$dbh->errstr());
	  return;
      };

      # Now get the new local user id
      my ($id) = $dbh -> selectrow_array("SELECT LAST_INSERT_ID()") or do {
	  print_bug("Error getting new ID when adding $username to the system: ".$dbh->errstr());
	  return;
      };

      my $template = HTML::Template -> new (filename => 'new_user_added.html');

      $template -> param(NAME => "$first_name $last_name");
      $template -> param(USERNAME => $username);

      print $template->output();

  }
  else {
      my $template = HTML::Template->new(filename => 'list_new_users.html');
      print $template -> output();
  }
}

sub get_isotopes {

  my @selected_ids = @_; # These are optional parameters used when constructing a list to edit
  my $sth = $dbh -> prepare("SELECT isotope_id,element,mw FROM Isotope ORDER BY mw");
  $sth -> execute() or do {
    print_bug("Couldn't list isotopes: ".$dbh->errstr());
    return undef;
  };

  my $isotopes;

  while (my ($id,$element,$mw) = $sth->fetchrow_array()){
    my $is_selected = 0;
    foreach (@selected_ids) {
      if ($id == $_) {
	$is_selected = 1;
	last;
      }
    }
    if ($is_selected) {
      push @$isotopes, {id => $id,
			element => $element,
			mw => $mw,
			selected => 1};

    }
    else {
      push @$isotopes, {id => $id,
			element => $element,
			mw => $mw};
    }
  }

  unless (defined $isotopes) {
    print_bug ("No isotopes listed in the database");
    return undef;
  }

  return $isotopes;
}

sub get_isotope_from_id {

  my ($id) = @_;

  my ($element,$mw,$half_life) = $dbh->selectrow_array("SELECT element,mw,half_life FROM Isotope WHERE isotope_id=?",undef,$id);

  unless ($element) {
    print_bug("Couldn't find element associated with id $id");
    return;
  }

  return ("$mw$element",$half_life);

}

sub get_buildings {

  my ($selected_id) = @_; # This is optional and only used when editing

  my $sth = $dbh -> prepare("SELECT building_id,number,name FROM Building ORDER BY number");

  $sth -> execute() or do {
    print_bug("Couldn't list buildings: ".$dbh->errstr());
    return undef;
  };

  my $buildings;

  while (my ($id,$number,$name) = $sth->fetchrow_array()){

    if ($selected_id and ($selected_id == $id)) {
      push @$buildings, {id => $id,
			 number => $number,
			 name => $name,
			selected => 1};

    }
    else {
      push @$buildings, {id => $id,
			 number => $number,
			 name => $name};
    }
  }

  unless (defined $buildings) {
    print_bug ("No buildings listed in the database");
    return undef;
  }

  return $buildings;
}

sub get_years {

  my ($selected_date) = @_; # Optional, used when editing
  my $selected_year;

  if ($selected_date) {
    ($selected_year) = split(/-/,$selected_date);
  }

  my $years;

  # We give all years to the one after the current year
  # so we don't get problems near the end of the current
  # year.

  for (2006..((localtime)[5]+1900+1)) {
    if ($selected_year and ($_ == $selected_year)) {
      push @$years ,{YEAR => $_,
		     SELECTED => 1};
    }
    else {
      push @$years ,{YEAR => $_};
    }
  }

  return $years;
}

sub get_months {
  my ($selected_date) = @_; # Optional, used when editing
  my $selected_month;

  if ($selected_date) {
    (undef,$selected_month) = split(/-/,$selected_date);
  }

  my $months;
  my $month_no = 1;
  foreach my $month_name (qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)) {
    if ($selected_month and ($month_no == $selected_month)) {
      push @$months ,{MONTH_NO => $month_no,
		      MONTH => $month_name,
		      SELECTED => 1};
    }
    else {
      push @$months ,{MONTH_NO => $month_no,
		      MONTH => $month_name,
		     };
    }
    ++$month_no;
  }

  return $months;
}

sub get_days {

  my ($selected_date) = @_; # Optional, used when editing
  my $selected_day;

  if ($selected_date) {
    (undef,undef,$selected_day) = split(/-/,$selected_date);
  }

  my $days;

  for (1..31) {
    if ($selected_day and ($_ == $selected_day)) {
      push @$days ,{DAY => $_,
		    SELECTED => 1};
    }
    else {
      push @$days ,{DAY => $_};
    }
  }

  return $days;

}

sub get_users {
  my ($selected_id) = @_; # Optional, used when editing

  $selected_id = 0 unless ($selected_id);

  my @users;

  my $sth = $dbh->prepare ("SELECT person_id,first_name,last_name FROM Person WHERE active=1 ORDER BY last_name,first_name");
  $sth -> execute() or do {
    print_bug("Couldn't list users: ".$dbh->errstr());
    return undef;
  };

  while (my ($id,$first,$last) = $sth -> fetchrow_array()) {
    if ($id == $selected_id) {
      push @users, {NAME => "$last, $first",
		    ID => $id,
		    SELECTED => 1};
    }
    else {
      push @users, {NAME => "$last, $first",
		    ID => $id,};
    }
  }

  return \@users;

}

sub get_active_drums {

  my ($type,$selected_id) = @_; # Selected used if we're editing

  unless ($type eq 'solid' or $type eq 'liquid') {
      print_bug("Didn't understand drum type '$type' when listing drums");
      exit;
  }

  my $sth = $dbh -> prepare("SELECT drum_id FROM Drum WHERE material=? AND date_removed IS NULL ORDER BY date_started");

  $sth -> execute($type) or do {
    print_bug("Couldn't list active drums: ".$dbh->errstr());
    return undef;
  };

  my $drums;

  while (my ($id) = $sth->fetchrow_array()){
    if ($selected_id and ($selected_id == $id)){
      push @$drums, {id => $id,
		     selected => 1};
    }
    else {
      push @$drums, {id => $id,};
    }
  }

  unless (defined $drums) {
    print_error ("No active drums listed in the database - use the Drums option to create one");
    return undef;
  }

  return $drums;
}


sub get_total_holding {

  my ($isotope_id,$date) = @_; # Date is optional

  unless ($date) {
    # Use tomorrow (all searches are done based on being less than $date)
    my ($year,$month,$day) = Add_Delta_Days(Today(),1);
    $date = "$year-$month-$day";
  }

  # Get the half life for this element
  my ($half_life) = $dbh->selectrow_array("SELECT half_life FROM Isotope WHERE isotope_id=?",undef,($isotope_id));

  unless ($half_life) {
    print_bug ("Couldn't determine half life for isotope $isotope_id:" .$dbh->errstr());
    return undef;
  }

  # All records are kept on a per-building basis we therfore have a
  # set of queries we'll need to perform on each building separately
  my $last_audit_sth = $dbh->prepare("SELECT date,activity FROM Audit WHERE building_id=? AND isotope_id=? AND date < ? ORDER BY date DESC limit 1");
  my $incoming_sth = $dbh->prepare("SELECT date,activity FROM Received WHERE isotope_id=? AND date >=? AND date < ? AND fully_decayed >= ? AND building_id=?");


  # We used to calculate holdings as everything which was currently on
  # site, including material which was decaying in a waste drum and
  # awaiting collection.  Following an inspection in April 2013 by 
  # Edwina Peck we were told that we should modify our system so that
  # the solid waste on site should NOT count in our total holdings.
  # The commented sth below is the original handle which excluded waste
  # which was on site.  The active version we're now using works in the
  # same way as the liquid disposals and removes the waste from the 
  # holdings as soon as the disposal is registered.  At that point the
  # waste is only recorded in the active drums section, not on any of the
  # reports.

  #  my $transfer_out_sth = $dbh->prepare("SELECT Transfer_disposal.date,Transfer_disposal.activity FROM Transfer_disposal,Drum WHERE Transfer_disposal.isotope_id=? AND Transfer_disposal.date >=? AND Transfer_disposal.date < ? AND Transfer_disposal.fully_decayed >= ? AND building_id=? AND Transfer_disposal.drum_id=Drum.drum_id AND Drum.date_removed IS NOT NULL AND Drum.date_removed <=?");

  my $transfer_out_sth = $dbh->prepare("SELECT Transfer_disposal.date,Transfer_disposal.activity FROM Transfer_disposal WHERE Transfer_disposal.isotope_id=? AND Transfer_disposal.date >=? AND Transfer_disposal.date < ? AND Transfer_disposal.fully_decayed >= ? AND building_id=?");

  my $liquid_out_sth = $dbh->prepare("SELECT date,activity FROM Liquid_disposal WHERE isotope_id=? AND date >=? AND date < ? AND fully_decayed >= ? AND building_id=?");

  my $buildings_sth = $dbh->prepare("SELECT building_id FROM Building");
  $buildings_sth ->execute() or do {
    print_bug("Couldn't list buildings: ".$dbh->errstr());
    return;
  };

  my $total_activity = 0;

  while (my ($building_id) = $buildings_sth->fetchrow_array()) {

    $last_audit_sth->execute($building_id,$isotope_id,$date) or do {
      print_bug("Couldn't get last audit date for istope $isotope_id and building $building_id: ".$dbh->errstr());
      return undef;
    };
    my ($audit_date,$audit_activity) = $last_audit_sth->fetchrow_array();
    my $base_activity = 0;
    if ($audit_date) {
      $base_activity = corrected_activity($audit_activity,$audit_date,$half_life,$date);
    }

    # Now add the incoming data
    my $base_date = "0-0-0";
    if ($audit_date) {
      $base_date = $audit_date;
    }
    $incoming_sth->execute($isotope_id,$base_date,$date,$date,$building_id) or do {
      print_bug ("Couldn't get incoming records for isotope $isotope_id after $base_date for building $building_id: ".$dbh->errstr());
      return undef;
    };

    while (my ($in_date,$in_activity) = $incoming_sth->fetchrow_array()) {
      $base_activity += corrected_activity($in_activity,$in_date,$half_life,$date);
    }

    # Now subtract the solid waste
    
    # This execute was for the old version of the sth where we needed to know whether waste was still
    # on site, but in a waste bin.  See the longer note above where the transfer_out_sth was created for
    # the gory details.
    # $transfer_out_sth->execute($isotope_id,$base_date,$date,$date,$building_id,$date) or do {


    $transfer_out_sth->execute($isotope_id,$base_date,$date,$date,$building_id) or do {
      print_bug ("Couldn't get solid waste records for isotope $isotope_id after $base_date for building $building_id: ".$dbh->errstr());
      return undef;
    };

    while (my ($solid_date,$solid_activity) = $transfer_out_sth->fetchrow_array()) {
      $base_activity -= corrected_activity($solid_activity,$solid_date,$half_life,$date);
    }

    # Now subtract the liquid waste
    $liquid_out_sth->execute($isotope_id,$base_date,$date,$date,$building_id) or do {
      print_bug ("Couldn't get liquid waste records for isotope $isotope_id after $base_date for building $building_id: ".$dbh->errstr());
      return undef;
    };

    while (my ($liquid_date,$liquid_activity) = $liquid_out_sth->fetchrow_array()) {
      $base_activity -= corrected_activity($liquid_activity,$liquid_date,$half_life,$date);
    }

    $total_activity += $base_activity;

  }

  return ($total_activity);
}

sub get_month_details {

  my ($isotope_id,$year,$month) = @_;

  # We always work from the first of the month to the first of the following month

  my $from_date = "$year-$month-01";
  $month +=1;
  if ($month == 13) {
    $year +=1;
    $month=1;
  }
  my $to_date = "$year-$month-01";

  my $total_incoming = 0;
  my $total_solid_transfer = 0;
  my $total_liquid_transfer = 0;
  my $total_liquid_disposal = 0;

  # Get the half life for this element
  my ($half_life) = $dbh->selectrow_array("SELECT half_life FROM Isotope WHERE isotope_id=?",undef,($isotope_id));

  unless ($half_life) {
    print_bug ("Couldn't determine half life for isotope $isotope_id:" .$dbh->errstr());
    return undef;
  }

  # All records are kept on a per-building basis we therfore have a
  # set of queries we'll need to perform on each building separately
  my $incoming_sth = $dbh->prepare("SELECT date,activity FROM Received WHERE isotope_id=? AND date >=? AND date < ?");
  my $drum_out_sth = $dbh->prepare("SELECT Transfer_disposal.activity, Transfer_disposal.date,Drum.date_removed,Drum.material FROM Drum,Transfer_disposal WHERE Drum.date_removed IS NOT NULL AND Drum.date_removed >=? AND Drum.date_removed < ? AND Transfer_disposal.drum_id=Drum.drum_id AND Transfer_disposal.isotope_id=?");
  my $liquid_out_sth = $dbh->prepare("SELECT date,activity FROM Liquid_disposal WHERE isotope_id=? AND date >=? AND date < ?");

  # Now add the incoming data
  $incoming_sth->execute($isotope_id,$from_date,$to_date) or do {
    print_bug ("Couldn't get incoming records for isotope $isotope_id between $from_date - $to_date : ".$dbh->errstr());
    return undef;
  };

  while (my ($in_date,$in_activity) = $incoming_sth->fetchrow_array()) {
    $total_incoming += $in_activity;
  }

  # Now do the transfer waste
  $drum_out_sth->execute($from_date,$to_date,$isotope_id) or do {
    print_bug ("Couldn't get solid waste drum records for isotope $isotope_id between $from_date - $to_date: ".$dbh->errstr());
    return undef;
  };

  while (my ($transfer_activity,$solid_date,$drum_date,$material) = $drum_out_sth->fetchrow_array()) {
      if ($material eq 'solid') {
	  $total_solid_transfer += corrected_activity($transfer_activity,$solid_date,$half_life,$drum_date);
      }
      elsif ($material eq 'liquid') {
	  $total_liquid_transfer += corrected_activity($transfer_activity,$solid_date,$half_life,$drum_date);
      }
  }

  # Now do the liquid waste
  $liquid_out_sth->execute($isotope_id,$from_date,$to_date) or do {
    print_bug ("Couldn't get liquid waste records for isotope $isotope_id between $from_date - $to_date: ".$dbh->errstr());
    return undef;
  };

  while (my ($liquid_date,$liquid_activity) = $liquid_out_sth->fetchrow_array()) {
    $total_liquid_disposal += $liquid_activity;
  }

  # To avoid lots of decimals, put things down to 3dp

  $total_incoming = sprintf("%.3f",$total_incoming);
  $total_solid_transfer = sprintf("%.3f",$total_solid_transfer);
  $total_liquid_transfer = sprintf("%.3f",$total_liquid_transfer);
  $total_liquid_disposal = sprintf("%.3f",$total_liquid_disposal);

  return ($total_incoming,$total_solid_transfer,$total_liquid_transfer,$total_liquid_disposal);
}



sub get_building_holding {

  my ($isotope_id,$building_id,$date) = @_; # Date is optional

  unless ($date) {
    # Use tomorrow (all searches are done based on being less than $date)
    my ($year,$month,$day) = Add_Delta_Days(Today(),1);
    $date = "$year-$month-$day";
  }

  # Get the half life for this element
  my ($half_life) = $dbh->selectrow_array("SELECT half_life FROM Isotope WHERE isotope_id=?",undef,($isotope_id));

  unless ($half_life) {
    print_bug ("Couldn't determine half life for isotope $isotope_id:" .$dbh->errstr());
    return undef;
  }

  my $last_audit_sth = $dbh->prepare("SELECT date,activity FROM Audit WHERE building_id=? AND isotope_id=? AND date < ? ORDER BY date DESC limit 1");
  my $incoming_sth = $dbh->prepare("SELECT date,activity FROM Received WHERE isotope_id=? AND date >=? AND date < ? AND fully_decayed >= ? AND building_id=?");
  my $transfer_out_sth = $dbh->prepare("SELECT date,activity FROM Transfer_disposal WHERE isotope_id=? AND date >=? AND date < ? AND fully_decayed >= ? AND building_id=?");
  my $liquid_out_sth = $dbh->prepare("SELECT date,activity FROM Liquid_disposal WHERE isotope_id=? AND date >=? AND date < ? AND fully_decayed >= ? AND building_id=?");

  $last_audit_sth->execute($building_id,$isotope_id,$date) or do {
    print_bug("Couldn't get last audit date for istope $isotope_id and building $building_id: ".$dbh->errstr());
    return undef;
  };
  my ($audit_date,$audit_activity) = $last_audit_sth->fetchrow_array();
  my $total_activity = 0;
  if ($audit_date) {
    $total_activity = corrected_activity($audit_activity,$audit_date,$half_life,$date);
  }

  # Now add the incoming data
  my $base_date = "0-0-0";
  if ($audit_date) {
    $base_date = $audit_date;
  }
  $incoming_sth->execute($isotope_id,$base_date,$date,$date,$building_id) or do {
    print_bug ("Couldn't get incoming records for isotope $isotope_id after $base_date for building $building_id: ".$dbh->errstr());
    return undef;
  };

  while (my ($in_date,$in_activity) = $incoming_sth->fetchrow_array()) {
    $total_activity += corrected_activity($in_activity,$in_date,$half_life,$date);
  }

  # Now subtract the solid waste
  $transfer_out_sth->execute($isotope_id,$base_date,$date,$date,$building_id) or do {
    print_bug ("Couldn't get solid waste records for isotope $isotope_id after $base_date for building $building_id: ".$dbh->errstr());
    return undef;
  };

  while (my ($solid_date,$solid_activity) = $transfer_out_sth->fetchrow_array()) {
    $total_activity -= corrected_activity($solid_activity,$solid_date,$half_life,$date);
  }

  # Now subtract the liquid waste
  $liquid_out_sth->execute($isotope_id,$base_date,$date,$date,$building_id) or do {
    print_bug ("Couldn't get liquid waste records for isotope $isotope_id after $base_date for building $building_id: ".$dbh->errstr());
    return undef;
  };

  while (my ($liquid_date,$liquid_activity) = $liquid_out_sth->fetchrow_array()) {
    $total_activity -= corrected_activity($liquid_activity,$liquid_date,$half_life,$date);
  }

  return ($total_activity);
}



sub corrected_activity {
  my ($activity,$orig_date,$half_life,$final_date) = @_;

  my ($year1,$month1,$day1) = split(/-/,$orig_date);

  # The final date is optional, and we just use today if it's not supplied
  my ($year2,$month2,$day2) = Today();

  if ($final_date) {
    ($year2,$month2,$day2) = split(/-/,$final_date);
  }


  my $elapsed = Delta_Days ($year1,$month1,$day1,$year2,$month2,$day2);

  if ($elapsed < 0) {
    print_bug ("Can't calculate decay for a date in the future! ($year1 $month1 $day1 $year2 $month2 $day2)");
    return undef;
  }

  my $current = $activity * (2**(-($elapsed/$half_life)));

  return ($current);

}

sub get_decayed_date {

  my ($orig_date,$activity,$half_life) = @_;

  my ($year,$month,$day) = split(/-/,$orig_date);

  # Calculates how many days are taken to reach 0.01 MBq

  my $days = (-((log(0.01/$activity))*$half_life))/log(2);

  $days = int($days) + 1;

  warn "Days is $days\n";

  my ($decayed_year,$decayed_month,$decayed_day) = Add_Delta_Days($year,$month,$day,$days);

  # MySQL can't handle years with > 4 digits, so for entries with a
  # really long halflife we have to do the best we can.  Obviously this
  # will leave us with a Y10k bug, but that's just how it is...

  if ($decayed_year > 9999) {
    $decayed_year = 9999;
    $decayed_month = 12;
    $decayed_day = 31;
  }

  warn "Date is $decayed_year-$decayed_month-$decayed_day\n";
  return ("$decayed_year-$decayed_month-$decayed_day");

}

sub print_bug {
  my ($message) = @_;

  $message = 'No message supplied' unless ($message);

  # Make sure something goes in the logs
  warn $message;

  # Now put out a generic error
  my $template = HTML::Template -> new (filename => 'bug.html');

  $template -> param(message => $message);

  print $template -> output();
}

sub print_error {

  my ($message) = @_;

  unless ($message) {
    print_bug("No message supplied when reporting an error");
    return;
  }

  my $template = HTML::Template -> new (filename => 'error.html');

  $template -> param(ERROR => $message);
  print $template->output();

}

sub get_user_details {

  my ($id) = @_;

  my ($first,$last,$phone,$email) = $dbh->selectrow_array("SELECT first_name,last_name,phone,email FROM Person WHERE person_id=?",undef,($id)) or do {
    print_bug ("Couldn't get person details for '$id': ".$dbh->errstr());
    return;
  };

  return($first,$last,$phone,$email);
}

sub check_valid_user {

  my ($username) = @_;

  my ($id) = $dbh -> selectrow_array("SELECT person_id FROM Person WHERE username=?",undef,($username));

  unless ($id) {
    # We need to create a new entry
    ($id) = add_new_user($username);
  }

  return ($id);

}

sub check_user {
  $username = $q -> remote_user();
  $username = "andrewss";

  unless ($username) {
    print_bug ("No authorisation when accessing the admin script");
    return 0;
  }

  if ($username =~ /^BABR\\(\w+)$/i) {
    $username = lc($1);
  }

  # Some clients (non-MS ones) don't send the domain, just the
  # username.  In these cases we'll take the full identifier
  # as the username.

  # Now we can check if the user is allowed
  # or not.

  foreach my $user_check (@allowed_users) {
    return (1) if ($username eq $user_check);
  }
  print_error ("You ($username) are not authorised to use the Radioactivity Admin interface");
  return(0);
}
