# Ensembl module for Bio::EnsEMBL::Analysis::RunnableDB::Funcgen
#
# Copyright (c) 2007 Ensembl
#
=head1 NAME

Bio::EnsEMBL::Analysis::RunnableDB::Fungen

=head1 SYNOPSIS

=head1 DESCRIPTION

This module is the base class for the Fungen Runnabledbs that act as an 
interface between the functional genomics database and the Funcgen Runnables 
both fetching input data and writing data back to the databases.

=head1 LICENCE

This code is distributed under an Apache style licence. Please see
http://www.ensembl.org/info/about/code_licence.html for details.

=head1 AUTHOR

Stefan Graf, Ensembl Functional Genomics - http://www.ensembl.org

=head1 CONTACT

Post questions to the Ensembl development list: ensembl-dev@ebi.ac.uk

=cut

package Bio::EnsEMBL::Analysis::RunnableDB::Funcgen;

use strict;
use warnings;
use Data::Dumper;

use Bio::EnsEMBL::Analysis::RunnableDB;
use Bio::EnsEMBL::Analysis::Config::General;
use Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor;

use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use Bio::EnsEMBL::Utils::Exception qw(throw warning stack_trace_dump);
use vars qw(@ISA);

@ISA = qw(Bio::EnsEMBL::Analysis::RunnableDB);

=head2 new

  Arg [1]   : Bio::EnsEMBL::Analysis::RunnableDB
  Arg [2]   : Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor
  Arg [3]   : Bio::EnsEMBL::Analysis
  Function  : create a Bio::EnsEMBL::Analysis::RunnableDB object
  Returntype: Bio::EnsEMBL::Analysis::RunnableDB
  Exceptions: throws if not passed either a dbadaptor, input id or
    an analysis object
  Example   : $rdb = $perl_path->new( -analysis => $self->analysis,
                                      -input_id => $self->input_id,
                                      -db => $self->adaptor->db );

=cut

sub new{

    print "Analysis::RunnableDB::Funcgen::new\n";
    my ($class,@args) = @_;
    my $self = $class->SUPER::new(@args);

    return $self;

}


################################################################################
### Declare and set up config variables
################################################################################

sub read_and_check_config {

    print "Analysis::RunnableDB::Funcgen::read_and_check_config\n";

    my ($self, $config) = @_;

    # For eFG we need to tweak the analysis logic_name a bit, which
    # contains the actual logic_name, experiment name, and result_set regexp
    # separated by colon.
    my ($logic_name, $experiment, $rset_regexp) = split(':', $self->analysis->logic_name);
    
    # Make sure we deal with the correct analysis object!!!
    $self->analysis->logic_name($logic_name);

    # Now read and check analysis config hash
    $self->SUPER::read_and_check_config($config);

    # and add/update analysis settings
    $self->analysis->program($self->PROGRAM);
    $self->analysis->program_file($self->PROGRAM_FILE);
    $self->analysis->program_version($self->VERSION);
    $self->analysis->parameters($self->PARAMETERS);
    $self->analysis->displayable(1);

    # Make sure we have the correct DB adaptors!!!
    $self->dnadb(Bio::EnsEMBL::DBSQL::DBAdaptor->new(%{ $self->DNADB })); 
    $self->efgdb(Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor->new(%{ $self->EFGDB })); 
    #print Dumper ($self->dnadb, $self->efgdb);

    # Set experiment
    my $e = $self->efgdb->get_ExperimentAdaptor->fetch_by_name($experiment);
    $self->experiment($e) 
        or throw("Can't fetch experiment with name ".$experiment);
    #print Dumper $self->experiment;

    # Set normalization method
    my $m = $self->efgdb->get_AnalysisAdaptor->fetch_by_logic_name($self->NORM_METHOD);
    $self->norm_method($m) 
        or throw("Can't fetch analysis object for norm method ".$self->NORM_METHOD);
    #print Dumper $self->norm_method;

    # Set result_set regular expression
    $self->RESULT_SET_REGEXP($rset_regexp) 
        or throw('No RESULT_SET_REGEXP defined!');

    # Save/set input_id as slice
    my $slice = $self->dnadb->get_SliceAdaptor->fetch_by_name($self->input_id);
    throw("Can't fetch slice ".$self->input_id) if (!$slice);
    $self->query($slice);
    #print Dumper $self->query;
    
    # make sure we have valid feature and data set objects incl. supporting sets
    #$self->check_Sets();
    
}

sub check_Analysis {

    my ($self) = @_;

    ### check if analysis with this logic_name already exists in the database
    ### and has got same settings
    
    my $logic_name = $self->analysis->logic_name();
    my $aa = $self->efgdb->get_AnalysisAdaptor;
    my $analysis = $aa->fetch_by_logic_name($logic_name);

    if ( ! defined $analysis->dbID ) { # NEW

        warn("Storing new analysis with logic name $logic_name.");
        $aa->store($self->analysis);

    } elsif ( $self->analysis->compare($analysis) ) { # UPDATE

        ### analysis compare
        # returns  1 if this analysis is special case of given analysis
        # returns  0 if they are equal
        # returns -1 if they are completely different

        warn('Analysis with logic name \''.$logic_name.'\' already '.
             'exists, but has different options! Updating analysis ...');

        $self->analysis->dbID($analysis->dbID);
        $self->analysis->adaptor($self->efgdb->get_AnalysisAdaptor);
        $aa->update($self->analysis);
 
    } else { # EXISTS

        warn('Analysis with logic name \''.$logic_name.'\' already '.
             'exists.');

    }

    $self->analysis($aa->fetch_by_logic_name($logic_name));

}

sub check_Sets {

    my ($self) = @_;

    ### get result sets to process and check that result_set, data_set, 
    ### feature_set are storable

    my $rsets = $self->fetch_ResultSets();

    ### get feature_set/data_set name by determining the longest common 
    ### prefix of the result_set names
    #print Dumper @{$self->ResultSets()};
    my @names = map { $_->name; } @{$self->ResultSets()};
    #print Dumper @names;

    my %hash = ();
    foreach my $n (@names) {
        my @chars = split(//, $n);

        my $string = '';
        foreach my $c (@chars) {
            $string .= $c;
            #print Dumper $string;
            $hash{$string}++;
        }
    }
    my $lcp = '';

    foreach (sort keys %hash) {
        last if ($hash{$_} < scalar(@$rsets));
        #print Dumper( $_, $hash{$_}, scalar(@$rsets) ) ;
        $lcp = $_;
    } 
    $lcp =~ s/_$//;
    
    my $set_name = $self->analysis->logic_name.'_'.$lcp; #.'_'.$self->DATASET_NAME;
    print 'Set name: ', $set_name, "\n";
    
    my $fsa = $self->efgdb->get_FeatureSetAdaptor();
    my $fset = $fsa->fetch_by_name($set_name);
    #print Dumper $fset;

    if ( ! defined $fset ) {

        $fset = Bio::EnsEMBL::Funcgen::FeatureSet->new
            (
             -analysis => $self->analysis,
             -feature_type => $self->feature_type,
             -cell_type => $self->cell_type,
             -name => $set_name,
             -type => 'annotated'
             );
        #print Dumper $fset;
        
        warn("Storing new feature set \'$set_name\'");
        eval { 
            $fset = ${$fsa->store($fset)}[0];
        };
        throw("Coudn't store feature set \'$set_name\': $!") if ($@);

    } else {

        warn("Feature set with name $set_name already exists.");

    }
    # save FeatureSet
    $self->feature_set($fset);

    my $dsa = $self->efgdb->get_DataSetAdaptor;
    my $dset = $dsa->fetch_by_name($set_name);
    #print Dumper $dset;

    if ( ! defined $dset ) {

        $dset = Bio::EnsEMBL::Funcgen::DataSet->new
            (
             -SUPPORTING_SETS     => $self->ResultSets,
             -FEATURE_SET         => $fset,
             -DISPLAYABLE         => 1,
             -NAME                => $set_name,
             -SUPPORTING_SET_TYPE => 'result',
             );
        #print Dumper $dset;

        warn("Storing new feature set \'$set_name\'");
        eval { $dset = ${$dsa->store($dset)}[0] };
        throw("Coudn't store data set \'$set_name\': $!") if ($@);

    } else {

        warn("Data set with name $set_name already exists.");

        # need to check whether ResultSets and supporting_sets are the same and 
        # possibly add ResultSet to supporting_sets

        my $ssets = $dset->get_supporting_sets();

        my %ssets_dbIDs = ();
        map { $ssets_dbIDs{$_->dbID}='' } (@{$ssets});
        map { 
            $dset->add_supporting_sets([ $_ ]) if (! exists $ssets_dbIDs{$_->dbID}); 
        } @{$self->ResultSets} 

    }
    # save DataSet
    $self->data_set($dset);

}

=head2 fetch_ResultSets

  Arg [1]   : Bio::EnsEMBL::Analysis::RunnableDB
  Function  : fetch and set ResultSets of interest
  Returntype: 1
  Exceptions: none
  Example   : 

=cut


sub fetch_ResultSets
{
    print "Analysis::RunnableDB::Funcgen::fetch_ResultSets\n";

    my $self = shift;
    #print Dumper $self;

    # fetch all available result_sets for given experiment and norm_method
    my $rsa = $self->efgdb->get_ResultSetAdaptor;
    my $rsets = $rsa->fetch_all_by_Experiment_Analysis
        ($self->experiment, $self->norm_method);
    print "No. of available ResultSets: ", scalar(@$rsets), "\n";

    # select only those result_sets that match regular expression
    my @rsets = ();
    my $regex = $self->RESULT_SET_REGEXP;
    foreach my $rset (@{$rsets}) {
        #print Dumper $rset->name();
        next if ($rset->name() !~ m/$regex/);
        push(@rsets, $rset);

        # check feature_type
        if (! defined $self->feature_type ) {
            $self->feature_type($rset->feature_type);
        } else {
            throw("replicates differ in feature types")
                if ($self->feature_type->dbID != $rset->feature_type->dbID);
        }

        # check cell_type
        if ( ! defined $self->cell_type() ) {
            $self->cell_type($rset->cell_type);
        } else {
            throw("replicates differ in cell types")
                if ($self->cell_type->dbID != $rset->cell_type->dbID);
        }

    }

    if (!@rsets) {
        
        my $rset_list = join(' ', map { $_->name } @{$rsets});
        throw ("RESULT_SET_REGEXP doesn't match any the following result set:\n$rset_list");
    }
    
    $self->ResultSets(\@rsets);

    print "Selected result sets: ", join(', ', map { $_->name } @rsets), 
    ' (in total ', scalar(@rsets), ")\n";

    return \@rsets;

}

################################################################################
### end of config
################################################################################

=head2 fetch_input

  Arg [1]     : Bio::EnsEMBL::Analysis::RunnableDB::Funcgen
  Description : fetch data out of database and create runnable
  Returns     : 1
  Exceptions  : none
  Example     : 

=cut

sub fetch_input {
    
    my ($self) = @_;
    print "Bio::EnsEMBL::Analysis::RunnableDB::Funcgen::fetch_input\n";
    
    #warn("write file: ", Dumper $self->db);
    
    my %result_features = ();
    foreach my $rset (@{$self->ResultSets}) {
        
        print join(" ", $rset->dbID, $rset->name), "\n";
        
        my $result_features = $rset->get_ResultFeatures_by_Slice($self->query());

        print "No. of ResultFeatures_by_Slice:\t", scalar(@$result_features), "\n";
        
        if (scalar(@$result_features) == 0) {
            warn("No result_features on slice ".$self->query()->name());
            exit 0;
        }

        my @result_features = ();
        my $ft_cnt = 1;
        foreach my $prb_ft (@{$result_features}) {
            #print join(" ", $self->query()->seq_region_name, 
            #           @$prb_ft, $ft_cnt++), "\n";
            push (@result_features,
                  [ $self->query()->seq_region_name, @$prb_ft, $ft_cnt++ ]);
        }
        
        $result_features{$rset->name} = \@result_features;
        
    }
    
    #print Dumper %result_features;
    
    #$self->result_features(\%features);
    #print Dumper $self->result_features();

    my %parameters_hash = ();

    if ($self->parameters_hash) {
        %parameters_hash = %{$self->parameters_hash};
    }

    $parameters_hash{-result_features} = \%result_features;

    my $runnable = 'Bio::EnsEMBL::Analysis::Runnable::Funcgen::'
        .$self->analysis->module;
    $runnable = $runnable->new
        (
         -query => $self->query,
         -program => $self->analysis->program_file,
         -analysis => $self->analysis,
         %parameters_hash
         );
    
    $self->runnable($runnable);
    
    return 1;
    
}

=head2 write_output

  Arg [1]   : Bio::EnsEMBL::Analysis::RunnableDB::Funcgen::Chipotle
  Function  : set analysis and slice on each feature
  Returntype: 1
  Exceptions: none
  Example   : 

=cut
    
sub write_output{
    
    print "Bio::EnsEMBL::Analysis::RunnableDB::Funcgen::write_output\n";
    my ($self) = @_;

    if (scalar(@{$self->output}) == 0) {
        warn("No features to annotate on slice ".$self->query->name.
             " for experiment ".$self->experiment->name()."!");
        exit 0;
    }
    
    # store analysis, feature set and data set
    # analysis was alredy been stored while checking config in read_and_check_config
    #$self->adaptor('Analysis')->store($self->analysis());
    if (! defined $self->feature_set->dbID) {
        $self->efgdb->get_FeatureSetAdaptor->store($self->feature_set());
    }
    if (! defined $self->data_set->dbID) {
        $self->efgdb->get_DataSetAdaptor->store($self->data_set());
    }
    
    ### annotated features
    
    my ($transfer, $slice);
    if($self->query->start != 1 || $self->query->strand != 1) {
        my $sa = $self->dnadb->get_SliceAdaptor;
        $slice = $sa->fetch_by_region($self->query->coord_system->name(),
                                      $self->query->seq_region_name(),
                                      undef, #start
                                      undef, #end
                                      undef, #strand
                                      $self->query->coord_system->version());
        $transfer = 1;
    } else {
        $slice = $self->query;
    }
    
#    my $af = $self->adaptor('AnnotatedFeature')->fetch_all_by_Slice_FeatureSet(
#		$self->query, $fset);

    my $fset = $self->feature_set;	
    my $fs_id = $fset->dbID();
    my $constraint = qq( af.feature_set_id = $fs_id );
    
    my $af = $self->efgdb->get_AnnotatedFeatureAdaptor->fetch_all_by_Slice_FeatureSet
        ($slice, $fset, $self->analysis->logic_name);
    
    print 'No. of annotated features already stored: '.scalar(@$af)."\n";
    print 'No. of annotated features to be stored: '.scalar(@{$self->output})."\n";
    
    if (@$af) {
        
        throw("NOT IMPORTING ".scalar(@{$self->output})." annotated features! Slice ".
              join(':', $self->query->seq_region_name,$self->query->start,$self->query->end).
                  " already contains ".scalar(@$af)." annotated features of feature set ".
              $fset->dbID.".");
        
    } else {
        my @af;
        foreach my $ft (@{$self->output}){
            
            #print Dumper $ft;
            my ($seqid, $start, $end, $score) = @{$ft};
                
            #print Dumper ($seqid, $start, $end, $score);
            my $af = Bio::EnsEMBL::Funcgen::AnnotatedFeature->new
                (
                 -slice         => $self->query,
                 -start         => $start,
                 -end           => $end,
                 -strand        => 0,
                 -display_label => $self->analysis->logic_name,
                 -score         => $score,
                 -feature_set   => $fset,
                 );
            
            # make sure feature coords are relative to start of entire seq_region
            if ($transfer) {
                #warn("original af:\t", join("\t", $af->start, $af->end), "\n");
                $af = $af->transfer($slice);
                #warn("remapped af:\t", join("\t", $af->start, $af->end), "\n");
            }
            push(@af, $af);
        }
        
        $self->efgdb->get_AnnotatedFeatureAdaptor->store(@af);
    }
    return 1;
}


### container for config hash parameter

sub PROGRAM {
    my ( $self, $value ) = @_;

    if ( defined $value ) {
        $self->{'_CONFIG_PROGRAM'} = $value;
    }

    if ( exists( $self->{'_CONFIG_PROGRAM'} ) ) {
        return $self->{'_CONFIG_PROGRAM'};
    } else {
        return undef;
    }
}

sub PROGRAM_FILE {
    my ( $self, $value ) = @_;

    if ( defined $value ) {
        $self->{'_CONFIG_PROGRAM_FILE'} = $value;
    }

    if ( exists( $self->{'_CONFIG_PROGRAM_FILE'} ) ) {
        return $self->{'_CONFIG_PROGRAM_FILE'};
    } else {
        return undef;
    }
}

sub VERSION {
    my ( $self, $value ) = @_;

    if ( defined $value ) {
        $self->{'_CONFIG_VERSION'} = $value;
    }

    if ( exists( $self->{'_CONFIG_VERSION'} ) ) {
        return $self->{'_CONFIG_VERSION'};
    } else {
        return undef;
    }
}

sub PARAMETERS {
    my ( $self, $value ) = @_;

    if ( defined $value ) {
        $self->{'_CONFIG_PARAMETERS'} = $value;
    }

    if ( exists( $self->{'_CONFIG_PARAMETERS'} ) ) {
        return $self->{'_CONFIG_PARAMETERS'};
    } else {
        return undef;
    }
}


### 

=head2 dnadb

  Arg [1]   : Bio::EnsEMBL::Analysis::RunnableDB
  Arg [2]   : Bio::EnsEMBL::DBSQL::DBAdaptor
  Function  : container for dbadaptor
  Returntype: Bio::EnsEMBL::DBSQL::DBAdaptor
  Exceptions: throws if not passed a Bio::EnsEMBL::DBSQL::DBConnection
    object
  Example   : 

=cut


sub dnadb{
  my ($self, $db) = @_;
  if($db){
      throw("Must pass RunnableDB:db a Bio::EnsEMBL::DBSQL::DBAdaptor ".
            "not a ".$db) 
          unless($db->isa('Bio::EnsEMBL::DBSQL::DBAdaptor'));
      $self->{'dnadb'} = $db;
  }
  return $self->{'dnadb'};
}

=head2 efgdb

  Arg [1]   : Bio::EnsEMBL::Analysis::RunnableDB
  Arg [2]   : Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor
  Function  : container for dbadaptor
  Returntype: Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor
  Exceptions: throws if not passed a Bio::EnsEMBL::Funcgen::DBSQL::DBConnection
    object
  Example   : 

=cut


sub efgdb{
  my ($self, $db) = @_;
  if($db){
      throw("Must pass RunnableDB:db a Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor ".
            "not a ".$db) 
          unless($db->isa('Bio::EnsEMBL::Funcgen::DBSQL::DBAdaptor'));
      $self->{'efgdb'} = $db;
  }
  return $self->{'efgdb'};
}

sub experiment {
    my ($self, $e) = @_;
    if ($e) {
      throw("Must pass a Bio::EnsEMBL::Funcgen::Experiment not a ".$e)
          unless($e->isa('Bio::EnsEMBL::Funcgen::Experiment'));         
      $self->{'experiment'} = $e;      
    }
    return $self->{'experiment'};
}

sub norm_method {
    my ($self, $m) = @_;
    if ($m) {
      throw("Must pass a Bio::EnsEMBL::Ananlysis not a ".$m)
          unless($m->isa('Bio::EnsEMBL::Analysis'));         
      $self->{'norm_method'} = $m;
    }
    return $self->{'norm_method'};
}

sub feature_type {
    my ($self, $ft) = @_;
    if ($ft) {
      throw("Must pass a Bio::EnsEMBL::Funcgen::FeatureType not a ".$ft)
          unless($ft->isa('Bio::EnsEMBL::Funcgen::FeatureType'));         
      $self->{'feature_type'} = $ft;
    }
    return $self->{'feature_type'};
}

sub cell_type {
    my ($self, $ct) = @_;
    if ($ct) {
      throw("Must pass a Bio::EnsEMBL::Funcgen::CellType not a ".$ct)
          unless($ct->isa('Bio::EnsEMBL::Funcgen::CellType'));         
      $self->{'cell_type'} = $ct;
    }
    return $self->{'cell_type'};
}

sub feature_set {
    my ($self, $fs) = @_;
    if ($fs) {
      throw("Must pass a Bio::EnsEMBL::Funcgen::FeatureSet not a ".$fs)
          unless($fs->isa('Bio::EnsEMBL::Funcgen::FeatureSet'));         
      $self->{'feature_set'} = $fs;
    }
    return $self->{'feature_set'};
}

sub data_set {
    my ($self, $ds) = @_;
    if ($ds) {
      throw("Must pass a Bio::EnsEMBL::Funcgen::DataSet not a ".$ds)
          unless($ds->isa('Bio::EnsEMBL::Funcgen::DataSet'));         
      $self->{'data_set'} = $ds;
    }
    return $self->{'data_set'};
}




sub ResultSets {
    my ($self, $sets) = @_;
    $self->{'ResultSets'} = $sets if ($sets);
    throw("No ResultSets in RunnableDB.") 
        if (!$self->{'ResultSets'});
    return $self->{'ResultSets'};
}



sub NORM_METHOD {
    my ( $self, $value ) = @_;

    if ( defined $value ) {
        $self->{'_CONFIG_NORM_METHOD'} = $value;
    }

    if ( exists( $self->{'_CONFIG_NORM_METHOD'} ) ) {
        return $self->{'_CONFIG_NORM_METHOD'};
    } else {
        return undef;
    }
}

sub RESULT_SET_REGEXP {
    my ( $self, $value ) = @_;

    if ( defined $value ) {
        $self->{'_CONFIG_RESULT_SET_REGEXP'} = $value;
    }

    if ( exists( $self->{'_CONFIG_RESULT_SET_REGEXP'} ) ) {
        return $self->{'_CONFIG_RESULT_SET_REGEXP'};
    } else {
        return undef;
    }
}

sub ANALYSIS_WORK_DIR {
    my ( $self, $value ) = @_;

    if ( defined $value ) {
        $self->{'_CONFIG_ANALYSIS_WORK_DIR'} = $value;
    }

    if ( exists( $self->{'_CONFIG_ANALYSIS_WORK_DIR'} ) ) {
        return $self->{'_CONFIG_ANALYSIS_WORK_DIR'};
    } else {
        return undef;
    }
}

sub EFGDB {
  my ( $self, $value ) = @_;

  if ( defined $value ) {
    $self->{'_CONFIG_EFGDB'} = $value;
  }

  if ( exists( $self->{'_CONFIG_EFGDB'} ) ) {
    return $self->{'_CONFIG_EFGDB'};
  } else {
    return undef;
  }
}

sub DNADB {
  my ( $self, $value ) = @_;

  if ( defined $value ) {
    $self->{'_CONFIG_DNADB'} = $value;
  }

  if ( exists( $self->{'_CONFIG_DNADB'} ) ) {
    return $self->{'_CONFIG_DNADB'};
  } else {
    return undef;
  }
}



1;
