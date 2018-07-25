=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the
EMBL-European Bioinformatics Institute
Copyright [2016-2018] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 CONTACT

Please email comments or questions to the public Ensembl
developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

Questions may also be sent to the Ensembl help desk at
<http://www.ensembl.org/Help/Contact>.

=head1 NAME

Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveCesar

=cut

=head1 DESCRIPTION

HiveCesar fetches the genes corresponding to the given array of gene_id or a single gene_id in source_db,
projects its exons based on the given Compara lastz alignment and the
CESAR2.0 aligner and builds single-transcript genes from these
projections to be written to target_db while filtering out the specified
transcripts by applying the filter in TRANSCRIPT_FILTER.
seqEdits and selenocysteine attributes are inserted in order to deal
with alignment gaps and seleno-like TGA stops which will be converted
into NNN triplets to make the best possible aligment.

=head1 OPTIONS

-iid                  gene_id or array of gene_id from the source_db corresponding to the
gene to be projected from the source_dna_db to the target_dna_db.
-output_path          Path where the output files will be stored.
-source_dna_db        Ensembl database containing the DNA sequences that
correspond to the input gene_id from the source_db.
-target_dna_db        Ensembl database containing the DNA sequences
corresponding to the target_db species where the gene_id will be
projected to.
-source_db            Ensembl database containing the genes whose
transcripts will be projected to the target species db target_db.
-target_db            Ensembl database containing the DNA sequences
corresponding to the target species the input gene_id will be projected to.
-compara_db           Compara database containing the lastz alignments
of the source and target species.
-method_link_type     Default to 'LASTZ_NET' so it works with the
Compara lastz alignments.
-exon_region_padding  Default to 50 to add 50 bases at each side of the
exons to be projected.
-cesar_path           Path to the directory containing the CESAR2.0
binary to be run (excluding the binary filename).
-canonical            If set to 1, then only the canonical transcript for each gene will be fetched from the source db.
-common_slice         If set to 1, all the transcripts projected from the same gene will be put on the same slice based
                      on the most common seq region name and min and max coordinates covering them. The projected transcripts
                      on the other slices will be discarded.
-TRANSCRIPT_FILTER    Hash containing the parameters required to apply
to the projected transcript to exclude some of them. Default to
ExonerateTranscriptFilter pid,cov 50,50 although note that the actual
implementation of this filter allows pid,cov below 50,50 in some cases.

=cut

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveCesar;

use warnings;
use strict;
use feature 'say';
use Scalar::Util 'reftype';
use List::Util qw[min max];
use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::GeneUtils qw(empty_Gene);

use Bio::SeqIO;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Compara::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Analysis::Tools::WGA2Genes::GeneScaffold;
use Bio::EnsEMBL::Analysis::Tools::ClusterFilter;
use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::TranscriptUtils
qw(replace_stops_with_introns                                                                     
   calculate_exon_phases                                                                  
   set_alignment_supporting_features                                                                  
   features_overlap);
use Bio::EnsEMBL::Analysis::Tools::Utilities qw(align_proteins);
use parent ('Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB');

sub param_defaults {
    return {
      iid => '',
      output_path => '',
      source_dna_db => '',
      target_dna_db => '',
      source_db => '',
      target_db => '',
      compara_db => '',
      method_link_type => 'LASTZ_NET',
      transcript_region_padding => 50,
      cesar_path => '',
      canonical => 0,
      common_slice => 0,
      #TRANSCRIPT_FILTER => {
      #                       OBJECT     => 'Bio::EnsEMBL::Analysis::Tools::ExonerateTranscriptFilter',
      #                       PARAMETERS => {
      #                         -coverage => 50,
      #                         -percent_id => 50,
      #                       },
      #                     }
   }
}

sub fetch_input {
  my($self) = @_;

  unless(-e $self->param('output_path')) {
    system("mkdir -p ".$self->param('output_path'));
  }

  my @input_id = ();
  if (reftype($self->param('iid')) eq "ARRAY") {
    @input_id = @{$self->param('iid')};
  } else {
    # make single-element array
    @input_id = ($self->param('iid'));
  }

  # Define the dna dbs
  my $source_dna_dba = $self->hrdb_get_dba($self->param('source_dna_db'));
  my $target_dna_dba = $self->hrdb_get_dba($self->param('target_dna_db'));
  $self->hrdb_set_con($source_dna_dba,'source_dna_db');
  $self->hrdb_set_con($target_dna_dba,'target_dna_db');

  # Define the source transcript and target transcript dbs
  my $source_transcript_dba = $self->hrdb_get_dba($self->param('source_db'));
  my $target_transcript_dba = $self->hrdb_get_dba($self->param('target_db'));
  $self->hrdb_set_con($source_transcript_dba,'source_transcript_db');
  $self->hrdb_set_con($target_transcript_dba,'target_transcript_db');

  # Define the compara db
  my $compara_dba = $self->hrdb_get_dba($self->param('compara_db'),undef,'Compara');
  $self->hrdb_set_con($compara_dba,'compara_db');

  # Get the genome db adaptor
  my $genome_dba = $compara_dba->get_GenomeDBAdaptor();

  # Retrieve the production names for the query and target species
  my $source_species = $source_transcript_dba->get_MetaContainerAdaptor->get_production_name();
  my $target_species = $target_transcript_dba->get_MetaContainerAdaptor->get_production_name();

  my $source_genome_db = $genome_dba->fetch_by_core_DBAdaptor($source_transcript_dba);
  my $target_genome_db = $genome_dba->fetch_by_core_DBAdaptor($target_transcript_dba);

  ########
  # check that the default assembly for the query and target agrees
  # with that for the method_link_species_set GenomeDBs
  ########

  my $source_assembly = $source_genome_db->assembly;
  my $target_assembly = $target_genome_db->assembly;

  my ($source_assembly_version, $target_assembly_version);
  eval {
    $source_assembly_version = $source_transcript_dba->get_CoordSystemAdaptor->fetch_by_name('toplevel',$source_genome_db->assembly);
    $target_assembly_version = $target_transcript_dba->get_CoordSystemAdaptor->fetch_by_name('toplevel',$target_genome_db->assembly);
  };
  if ($@) {
    $self->throw("Had trouble fetching coord systems for ".
                 $source_genome_db->assembly." and ".$target_genome_db->assembly.
                 " from core dbs:\n".$@);
  }
 
  #########
  # get the compara data: MethodLinkSpeciesSet, reference DnaFrag,
  # and all GenomicAlignBlocks
  #########
  my $mlss = $compara_dba->get_MethodLinkSpeciesSetAdaptor->fetch_by_method_link_type_GenomeDBs($self->param('method_link_type'),[$source_genome_db,$target_genome_db]);

  if (!($mlss)) {
    $self->throw("No MethodLinkSpeciesSet for :\n".$self->param('method_link_type')."\n".$source_species."\n".$target_species);
  }

  foreach my $ii (@input_id) {

    my $gene = $source_transcript_dba->get_GeneAdaptor->fetch_by_dbID($ii);
    my @unique_translateable_transcripts = $self->get_unique_translateable_transcripts($gene,$self->param('canonical'));
    my $transcript_align_slices;
    my $genomic_align_block_adaptor = $compara_dba->get_GenomicAlignBlockAdaptor();
    my $transcript_region_padding = $self->param('transcript_region_padding');

my $debug_transcript_index = 0;

    foreach my $transcript (@unique_translateable_transcripts) {
     
      my $transcript_group_id_lengths = {};
      my $transcript_group_id_min_starts = {};
      my $transcript_group_id_max_ends = {};
      my $transcript_group_id_seq_region_names = {};
      my $transcript_group_id_seq_region_strands = {};
     
say "transcript index: ".$debug_transcript_index++;     
      my $transcript_padded_start = $transcript->start()-$transcript_region_padding;
      if ($transcript_padded_start < 0) {
        $transcript_padded_start = 0;
      }

      my $transcript_padded_end = $transcript->end()+$transcript_region_padding;
      if ($transcript_padded_end > $gene->slice()->length()) {
        $transcript_padded_end = $gene->slice()->length();
      }

      my $slice_adaptor = $source_dna_dba->get_SliceAdaptor();
      my $transcript_slice = $slice_adaptor->fetch_by_region($transcript->slice()->coord_system_name(),$transcript->slice()->seq_region_name(),$transcript_padded_start,$transcript_padded_end);

say "------------transcript slice: ".$transcript_slice->coord_system_name()." ".$transcript_slice->name()."\n"."length of transcript slice seq: ".length($transcript_slice->seq());
#sleep(5);
      my $genomic_align_blocks = $genomic_align_block_adaptor->fetch_all_by_MethodLinkSpeciesSet_Slice($mlss,$transcript_slice);
      my $transcript_slices = [];
      
      
      
      foreach my $genomic_align_block (@{$genomic_align_blocks}) {
        my $gab = $genomic_align_block->restrict_between_reference_positions($transcript_padded_start,$transcript_padded_end);
        
#my $gab_slice = $restricted_gab->slice();
#print("restricted genomic align block slice: ".$gab_slice->name()." ".$gab_slice->seq_region_start()." ".$gab_slice->seq_region_end()." ".$gab_slice->seq_region_name()."\n"."length of gab slice seq: ".length($gab_slice->seq())." block group id,level id: ".$restricted_gab->group_id().",".$restricted_gab->level_id()."\n");        
        if ($gab) {
          my $gab_group_id = $gab->group_id();
          foreach my $genomic_align (@{$gab->get_all_non_reference_genomic_aligns()}) {
            my $genomic_align_slice = $genomic_align->get_Slice();
            $transcript_group_id_lengths->{$gab_group_id} += length($genomic_align_slice->seq());
            
            if (!($transcript_group_id_min_starts->{$gab_group_id})) {
              $transcript_group_id_min_starts->{$gab_group_id} = $genomic_align_slice->start();
            } else {
              $transcript_group_id_min_starts->{$gab_group_id} = min($transcript_group_id_min_starts->{$gab_group_id},
                                                                     $genomic_align_slice->start());
            }
            $transcript_group_id_max_ends->{$gab_group_id} = max($transcript_group_id_max_ends->{$gab_group_id},
                                                                 $genomic_align_slice->end());
            $transcript_group_id_seq_region_names->{$gab_group_id} = $genomic_align_slice->seq_region_name();
            $transcript_group_id_seq_region_strands->{$gab_group_id} = $genomic_align_slice->strand();
            
            #push(@{$transcript_slices},$genomic_align_slice);
#say "GAS gab id: ".$genomic_align->genomic_align_block_id();
            say "GAS NAME: ".$genomic_align_slice->name();
            say "GAS START: ".$genomic_align_slice->start();
            say "GAS END: ".$genomic_align_slice->end();
            say "GAS SEQ length: ".length($genomic_align_slice->seq());         
          } 
        }
      }

      my @sorted_group_ids = sort {$$transcript_group_id_lengths{$a} <=> $$transcript_group_id_lengths{$b}} keys %{$transcript_group_id_lengths};
      my $longest_group_id = $sorted_group_ids[-1];
     
      if ($longest_group_id) {

        print "longest group is: ".$longest_group_id."\n";
        print "length: ".$transcript_group_id_lengths->{$longest_group_id}."\n";
      
        my $sa = $self->hrdb_get_con('target_dna_db')->get_SliceAdaptor();       
        my $target_transcript_slice = $sa->fetch_by_region(undef,
                                                  $transcript_group_id_seq_region_names->{$longest_group_id},
                                                  $transcript_group_id_min_starts->{$longest_group_id},
                                                  $transcript_group_id_max_ends->{$longest_group_id},
                                                  $transcript_group_id_seq_region_strands->{$longest_group_id});
say "===SOURCE TRANSCRIPT SLICE: ".$transcript_slice->name()." length: ".$transcript_slice->length()."\nSeq:\n".$transcript_slice->seq();
say "===TARGET TRANSCRIPT SLICE: ".$target_transcript_slice->name()." length: ".$target_transcript_slice->length()."\nSeq:\n".$target_transcript_slice->seq();

my $transcript_align_slice_strand = substr($target_transcript_slice->name(),-2);
if ($transcript_align_slice_strand eq "-1") { # check if strand is -1
  my $temp_seq = reverse($target_transcript_slice->seq());
  $temp_seq =~ tr/atgcATGC/tacgTACG/;
  
  say "===TARGET TRANSCRIPT SLICE: ".$target_transcript_slice->name()." length: ".$target_transcript_slice->length()."\nSeq reversed:\n".$temp_seq;
}

        $transcript_align_slices->{$transcript->dbID()} = $target_transcript_slice;
      }
    }
    
    if (\@unique_translateable_transcripts and $transcript_align_slices and $gene) {
      $self->parent_genes($gene);
      $self->unique_translateable_transcripts(\@unique_translateable_transcripts);
      $self->transcript_align_slices($transcript_align_slices);
    } else {
      $self->warning("Gene ".$gene->dbID()."( ".$gene->stable_id()." ) does not have unique_translateable_transcripts or transcript_align_slices.");
    }

  } # foreach my $ii

  # check that each gene has a set of unique translateable transcripts and transcript align slices
  if (scalar(@{$self->parent_genes()}) != scalar(@{$self->unique_translateable_transcripts()}) or
      scalar(@{$self->parent_genes()}) != scalar(@{$self->transcript_align_slices()})) {
    $self->throw("Different number of elements in parent_genes, unique_translateable_transcripts and transcript_align_slices arrays.");
  }
}

sub run {
  my ($self) = @_;

  my $gene_index = 0;
  foreach my $gene (@{$self->parent_genes()}) {

    my $transcripts = @{$self->unique_translateable_transcripts()}[$gene_index];

    my @projected_transcripts = ();
    my $fail_count = 0;

    my $himem_required = 0;

    foreach my $transcript (@{$transcripts}) {
     
     
my $transcript_align_slice = @{$self->transcript_align_slices()}[$gene_index]->{$transcript->dbID()};  
my $transcript_align_slice_strand = substr($transcript_align_slice->name(),-2);  
  
if ($transcript->strand() == -1 or $transcript_align_slice_strand eq "-1") {
say "skipping transcript on -1 strand";
  next;
}     
     
     
      my $projected_transcript = $self->project_transcript($transcript,$gene_index);
      if ($projected_transcript == -1) {
        # it will be retried in the himem analysis
        say "Failed to project transcript due to himem required: ".$transcript->stable_id();
        $fail_count++;
        $himem_required = 1;
        last;
      } elsif ($projected_transcript) {
        push(@projected_transcripts,$projected_transcript);
      } else {
        say "Failed to project transcript: ".$transcript->stable_id();
        $fail_count++;
      }
    }

    if (!$himem_required) {
      $self->build_gene(\@projected_transcripts,$gene_index,$self->param('canonical'));
    }
    
    say "Had a total of ".$fail_count."/".scalar(@{$transcripts})." failed transcript projections for gene ".$gene->dbID();
    $gene_index++;
  }
}


sub write_output {
  my ($self) = @_;

  my $gene_adaptor = $self->hrdb_get_con('target_transcript_db')->get_GeneAdaptor;
  my $slice_adaptor = $self->hrdb_get_con('target_transcript_db')->get_SliceAdaptor;

  my $genes = $self->output_genes();
  foreach my $gene (@{$genes}) {
    say "Storing gene: ".$gene->start.":".$gene->end.":".$gene->strand;
    empty_Gene($gene);    
    $gene_adaptor->store($gene);
  }
}

sub build_gene {
  my ($self,$projected_transcripts,$gene_index,$canonical) = @_;

  if (scalar(@$projected_transcripts) > 0) {
    my $analysis = Bio::EnsEMBL::Analysis->new(
                                                -logic_name => 'cesar',
                                                -module => 'HiveCesar',
                                              );

    say "Building genes from projected transcripts";

    my $projected_gene = @{$self->parent_genes}[$gene_index];
    $projected_gene->flush_Transcripts();
    say "Source gene SID: ".$projected_gene->stable_id();

    if ($self->param('common_slice')) {
      $self->set_common_slice($projected_transcripts);
    }

    foreach my $projected_transcript (@$projected_transcripts) {
      # do not store transcripts containing stops
      #if ($projected_transcript->translate()) {
      #  my $projected_transcript_translate_seq = $projected_transcript->translate()->seq();
      #  my $num_stops = $projected_transcript_translate_seq =~ s/\*/\*/g;
      #  if ($num_stops > 0) {
      #    say "The projected transcript has been filtered out because its translation contains stops (".$num_stops." stops).";
      #  } else {
          # filter out transcripts below given pid and cov
          if ($self->TRANSCRIPT_FILTER) {
#print("TRANSCRIPT FILTER defined\n");
            if (scalar(@{$projected_transcript->get_all_supporting_features()}) > 0) {
              my $filtered_transcripts = $self->filter->filter_results([$projected_transcript]);
              if (scalar(@$filtered_transcripts) > 0) {
               
                if ($self->param('common_slice')) {
                  $projected_gene->add_Transcript($projected_transcript);
                  $projected_gene->analysis($analysis);
                  $self->output_genes($projected_gene);
                } else {
                  my $single_transcript_gene = Bio::EnsEMBL::Gene->new();
                  $single_transcript_gene->add_Transcript($projected_transcript);
                  $single_transcript_gene->analysis($analysis);
                  $self->output_genes($single_transcript_gene);
                }
                
              } else {
                say "The projected transcript has been filtered out because its pid and cov are too low.";
              }
            }
          } else {
#print("TRANSCRIPT FILTER NOT defined\n");
          
            if ($self->param('common_slice')) {
              $projected_gene->add_Transcript($projected_transcript);
              $projected_gene->analysis($analysis);
              $self->output_genes($projected_gene);
            } else {
              my $single_transcript_gene = Bio::EnsEMBL::Gene->new();
              $single_transcript_gene->add_Transcript($projected_transcript);
              $single_transcript_gene->analysis($analysis);
              $self->output_genes($single_transcript_gene);
            }

          }
      #  }
      #} else {
        #say "The projected gene does not translate.";
      #}
    }
  }
}

sub largest_value_mem {
# it returns the key containing the largest value in a given hash
  my $hash = shift;
  my ($key,@keys) = keys %$hash;
  my ($big,@vals) = values %$hash;

  for (0 .. $#keys) {
    if ($vals[$_] > $big) {
      $big = $vals[$_];
      $key = $keys[$_];
    }
  }
  $key
}

sub set_common_slice {
# it sets the same slice for all transcripts so they can be added
# to the same gene later based on the most common seq region name
# and minimum and maximum transcript coordinates for that seq region name
  my ($self,$projected_transcripts) = @_;

  my %common_regions;
  my $min = 9999999999999999;
  my $max = 0;
  my $sa = $self->hrdb_get_con('target_dna_db')->get_SliceAdaptor(); 

  foreach my $projected_transcript (@$projected_transcripts) {
    $common_regions{$projected_transcript->seq_region_name()} += 1;
print "foreach my proj t set common slice\n";
  }

    use Data::Dumper;
    # simple procedural interface
    print Dumper(%common_regions);


  my $most_common_seq_region_name = largest_value_mem(\%common_regions);
  
print "MOST:".$most_common_seq_region_name."\n";

  foreach my $projected_transcript (@$projected_transcripts) {
    if ($projected_transcript->seq_region_name() eq $most_common_seq_region_name) {
      $min = min($projected_transcript->seq_region_start(),$min);
      $max = max($projected_transcript->seq_region_end(),$max);
    }
  }

  my $common_slice = $sa->fetch_by_region(undef,$most_common_seq_region_name,$min,$max);

  foreach my $projected_transcript (@$projected_transcripts) {
    $projected_transcript->slice($common_slice);
  }

  print("Common slice set to: ".$common_slice->name()."\n");
}

sub project_transcript {
  my ($self,$transcript,$gene_index) = @_;

  #my $transcript_align_slices = @{$self->transcript_align_slices()}[$gene_index]->{$transcript->dbID()};
  my $transcript_align_slice = @{$self->transcript_align_slices()}[$gene_index]->{$transcript->dbID()};  
  my $transcript_align_slice_strand = substr($transcript_align_slice->name(),-2);

  if (!$transcript_align_slice) {
    $self->warning("transcript_align_slice is empty for transcript dbID ".$transcript->dbID()." (stable ID ".$transcript->stable_id_version()." ) gene index: ".$gene_index);
    return 0;
  }

  #if (!$transcript_align_slices) {
  #  return 0;
  #} elsif (scalar(@{$transcript_align_slices}) <= 0) {
  #  return 0;
  #}

  # set output filename
  my $rand = int(rand(10000));
  # Note as each accession will occur in only one file, there should be no problem using the first one
  my $outfile_path = $self->param('output_path')."/cesar_".$$."_".$transcript->stable_id()."_".$rand.".fasta";
  $self->files_to_delete($outfile_path);

  open(OUT,">".$outfile_path);

EXON:  foreach my $exon (@{$transcript->get_all_translateable_Exons()}) {
    my $seq = $exon->seq->seq();
    my $phase = $exon->phase();
    my $end_phase = $exon->end_phase();

    my $start_coord;
    my $end_coord;

    # Find 5' split codon and lowercase bases
    if ($phase == 0 or $phase == -1) {
      ;
    } elsif($phase == 1) {
      my $split_codon = substr($seq,0,2);
      say "Split coding base start: ".lc($split_codon);
      $seq = lc($split_codon).substr($seq,2);
    } elsif($phase == 2) {
      my $split_codon = substr($seq,0,1);
      say "Split coding base start: ".lc($split_codon);
      $seq = lc($split_codon).substr($seq,1);
    } else {
      $self->throw("Unexpected phase found for exon ".$exon->stable_id." (".$exon->dbID()."): ".$phase);
    }

    # Find 3' split codon and lowercase bases
    if ($end_phase == 0 or $end_phase == -1) {
      ;
    } elsif($end_phase == 1) {
      my $split_codon = substr($seq,length($seq)-1);
      say "Split coding base end: ".lc($split_codon);
      $seq = substr($seq,0,length($seq)-1).lc($split_codon);
    } elsif($end_phase == 2) {
      my $split_codon = substr($seq,length($seq)-2);
      say "Split coding base end: ".lc($split_codon);
      $seq = substr($seq,0,length($seq)-2).lc($split_codon);
    } else {
      $self->throw("Unexpected end phase found for exon ".$exon->stable_id." (".$exon->dbID()."): ".$end_phase);
    }

    # remove bases from the 3' end in case the sequence is not multiple of 3
    while (($seq =~ tr/ACGTN//)%3 != 0) {
      $seq = substr($seq,0,length($seq)-1);
      say("Removed last base because the end phase is -1 and the sequence is not multiple of 3.");
    }

    # replace TGA stops/selenocysteines with NNN so CESAR2.0 makes it match with anything
    my $i_step = 1;
    for (my $i = 0; $i < length($seq); $i += $i_step) {
      my $base_1 = substr($seq,$i,1);
      if ($base_1 !~ /[acgtn]/) {
        # we have reached the first (upper case or -) base of the exon sequence
        $i_step = 3;
      }
      if ($i_step == 3) {
        my $base_2 = substr($seq,$i+1,1);
        my $base_3 = substr($seq,$i+2,1);
          if ($base_1 eq "T" and
              $base_2 eq "G" and
              $base_3 eq "A" and
              $i+$i_step < length($seq)) { # ignore the last stop codon
            # selenocysteine stop found needs to be replaced with cysteine
            $seq = substr($seq,0,$i)."NNN".substr($seq,$i+3);
            $exon->{'selenocysteine'} = $i; # create new exon attribute to store the start of the selenocysteine

            $self->warning("Potential selenocysteine/TGA stop codon found at position $i (including lower case flanks). Exon ".$exon->stable_id().". Sequence (including lower case flanks): $seq");
          } elsif ( ($base_1 eq "T" and
                     $base_2 eq "A" and
                     ($base_3 eq "A" or $base_3 eq "G")) and
                    $i+$i_step < length($seq) ) { # ignore the last stop codon
            $self->warning("Stop codon TAA or TAG found in reference. Exon ".$exon->stable_id()." skipped.");
            next EXON;
          }
       }
    }
    
    # replace any base different from A,C,G,T with N
    $seq =~ tr/ykwmsrdvhbxYKWMSRDVHBX/nnnnnnnnnnnNNNNNNNNNNN/;
    
    say "S2: ".$seq;

    say OUT ">".$transcript->stable_id()."_".$exon->stable_id();
    say OUT $seq;
  }

  # CESAR2.0 requires references and queries to be separated by a line starting with '#'.
  # References are the exons (together with their reading frame) that you want to align to the query sequence.
  say OUT "#";

  #foreach my $transcript_align_slice (@{$transcript_align_slices}) {
    say $transcript->stable_id().": ".$transcript_align_slice->name();
    say OUT ">".$transcript_align_slice->name();
    
    my $transcript_align_slice_seq = $transcript_align_slice->seq();
    
    # replace any base different from A,C,G,T with N
    $transcript_align_slice_seq =~ tr/ykwmsrdvhbxRYKWMSDVHBX/nnnnnnnnnnnNNNNNNNNNNN/;
    
    #if ($transcript->strand() == -1) {
    
    # transcript align slice already comes reversed from the Compara API
    #if ($transcript_align_slice_strand eq "-1") { # check if strand is -1
    #  my $temp_seq = reverse($transcript_align_slice_seq);
    #  $temp_seq =~ tr/atgcATGC/tacgTACG/;
    #  say OUT $temp_seq;
    #} else {
      say OUT $transcript_align_slice_seq;
    #}
  #}
  close OUT;

  chdir $self->param('cesar_path');
  my $cesar_command = $self->param('cesar_path')."/cesar ".$outfile_path." --clade human ";
  if ($self->param('cesar_mem')) {
    $cesar_command .= "--max-memory ".$self->param('cesar_mem'); # set max mem in GB
  }

  say $cesar_command;

  my $cesar_output;
  $cesar_output = `$cesar_command 2>&1`;
  my $fces_name_tmp = $outfile_path.".ces.tmp";
  my $fces_name = $outfile_path.".ces";

  if ($cesar_output =~ /The memory consumption is limited/) {
    my $output_hash = {};
    push(@{$output_hash->{'iid'}},@{$self->parent_genes()}[$gene_index]->dbID());

    $self->dataflow_output_id($output_hash,-1);
    $self->warning("cesar command FAILED and it will be passed to cesar_himem: ".$cesar_command.". Gene ID: ".@{$self->parent_genes()}[$gene_index]->dbID()."\n");
    say "projected exon will return -1";
    return (-1);
  } elsif ($cesar_output =~ /CRITICAL/) {
    $self->throw("cesar command FAILED: ".$cesar_command."\n");
  } else {
    open(FCES,'>',$fces_name_tmp) or die $!;
    print FCES $cesar_output;
    close(FCES);
    system("grep -v WARNING $fces_name_tmp > $fces_name"); # remove CESAR2.0 warnings
  }

  $self->files_to_delete($fces_name_tmp);
  $self->files_to_delete($fces_name);
  my $projected_transcript = $self->parse_transcript($transcript,$fces_name);
#  while(my $file_to_delete = shift(@{$self->files_to_delete})) {
#    system('rm '.$file_to_delete);
#  }


#LOOP THROUGH TRANSCRIPT EXONS AND MATCH THEN TO THE PROJECTED EXON
  if ($projected_transcript) {
      
   
#    
#    foreach my $projected_exon ($projected_transcript->get_all_Exons()) {  
#      my $projected_exon_seq = $projected_exon->seq()->seq();
#      # find selenocysteines
#      if ($exon->{'selenocysteine'}) {
#        my $i_step = 1;
#        for (my $i = 0; $i < length($projected_exon_seq); $i += $i_step) {
#          my $base_1 = substr($projected_exon_seq,$i,1);
#          if ($base_1 !~ /[acgt]/) {
#            # we have reached the first (upper case or -) base of the exon sequence
#            $i_step = 3;
#          }
#          if ($i_step == 3) {
#            my $base_2 = substr($projected_exon_seq,$i+1,1);
#            my $base_3 = substr($projected_exon_seq,$i+2,1);
#             if ($base_1 eq "T" and
#                 $base_2 eq "G" and
#                 $base_3 eq "A" and
#                 ($exon->{'selenocysteine'} == $i) and
#                 $i+$i_step < length($seq)) { # ignore the last stop codon
#               $projected_exon->{'selenocysteine'} = $i;
#             }
#          }
#        }
#      }
#    }
    return ($projected_transcript);
  } else {
    return (0);
  }
}

sub parse_transcript {
  my ($self,$source_transcript,$projected_outfile_path) = @_;
  
  open(IN,$projected_outfile_path);
  my @projection_array = <IN>;
  close IN;
  
  # remove last line if blank and not corresponding to the last sequence
  if ($projection_array[-1] =~ /^\$/ and $projection_array[-3] =~ /^>/) {
    pop(@projection_array);
  }
  
  my $reference_exon_header = shift(@projection_array);
  my $source_seq =  shift(@projection_array);
  my $slice_name = shift(@projection_array);
  my $proj_seq = shift(@projection_array);

  if (scalar(@projection_array) > 0) {
    $self->throw("Output file has more than one projection. The projection having fewer gaps will be chosen. Transcript: ".$source_transcript->stable_id());
  }

  chomp($source_seq);
  chomp($proj_seq);
  
  if ($slice_name !~ /^>(.+\:.+\:.+\:)(.+)\:(.+)\:(.+)$/) {
    $self->throw("Couldn't parse the header to get the slice name. Header: ".$slice_name);
  }

  my $proj_transcript_slice_name = $1;
  my $transcript_start_coord = $2;
  my $transcript_end_coord = $3;
  my $original_proj_transcript_strand = $4;
  my $strand = $original_proj_transcript_strand;
  
  # Reverse the strand if the slice of the source transcript is on the negative strand
  # (in these cases we have reverse complemented the slice sequence when projecting)
  #if ($source_transcript->strand == -1) {
  #  $strand = $strand * -1;
  #}
  
  $source_seq =~ /( *)([\-atgcnATGCN ]+[-atgcnATGCN]+)( *)/;
  
  my $transcript_left_flank = $1;
  my $source_transcript_align = $2;
  my $transcript_right_flank = $3;
  my $exon_offset_from_start = 0;

say "transcript_left_flank: ".$transcript_left_flank;
say "source_transcript_align: ".$source_transcript_align;
say "transcript_right_flank: ".$transcript_right_flank;


say "orig proj_transcript_slice_name: ".$proj_transcript_slice_name;

  if ($strand == 1) {
    #$transcript_start_coord += length($transcript_left_flank);
    #$transcript_end_coord -= length($transcript_right_flank);
    $exon_offset_from_start = length($transcript_left_flank);
  } else {
    #$transcript_start_coord += length($transcript_right_flank);
    #$transcript_end_coord -= length($transcript_left_flank);
    
    #$exon_offset_from_start = length($transcript_right_flank);
    $exon_offset_from_start = length($transcript_left_flank);
  }

  #$proj_transcript_slice_name .= join(":",($transcript_start_coord,$transcript_end_coord,$strand));
  $proj_transcript_slice_name .= join(":",($transcript_start_coord,$transcript_end_coord,$original_proj_transcript_strand));
  my $slice_adaptor = $self->hrdb_get_con('target_dna_db')->get_SliceAdaptor();
  
say "proj_transcript_slice_name: ".$proj_transcript_slice_name;

  #my $proj_transcript_slice = $slice_adaptor->fetch_by_name($proj_transcript_slice_name)->seq_region_Slice();
  my $proj_transcript_slice = $slice_adaptor->fetch_by_name($proj_transcript_slice_name);

say "proj_transcript_slice start: ".$proj_transcript_slice->start();
say "proj_transcript_slice end: ".$proj_transcript_slice->end();

  if (!($proj_transcript_slice)) {
    $self->throw("Couldn't retrieve a slice for transcript: ".$proj_transcript_slice_name);
  }

  # parse the projected exons
  
  #my @exon_sequences = ($transcript_align =~ /([\-atgcnATGCN]+)/g);

  #if (scalar(@exon_sequences) != scalar(@{$source_transcript->get_all_translateable_Exons()})) {
  #  # CESAR2.0 can merge exons in some cases so these numbers are allowed to differ
  #  $self->warning("The number of projected exons is different from the number of source transcript exons.");
  #}

  $proj_seq =~ tr/\-//d;
say "proj_seq without dashes: ".$proj_seq;

  my @projected_exons = ();

  #foreach my $exon_sequence (@exon_sequences) {
  #foreach my $exon_sequence ($transcript_align =~ /([\-atgcnATGCN]+)/g) {
   #while ($source_transcript_align =~ /([\-atgcnATGCN]+)/g) {
    while ($proj_seq =~ /([ATGCN]+)/g) {
    
     my $exon_sequence = $1;
     
     # @- and @+ are the start and end positions of the last match.
     # $-[0] and $+[0] are the entire pattern.
     # $-[N] and $+[N] are the $N submatches.
     my $exon_start;
     my $exon_end;
     my $proj_transcript_slice_length = length($proj_transcript_slice->seq());
say "proj_transcript_slice_length is: ".$proj_transcript_slice_length;
say "strand is: ".$strand;
     if ($strand == -1) {
say "strand is -1";
       $exon_start = $proj_transcript_slice_length-($+[0]-1); # -1 because $+[] gives the index of the character following the match, not the last character of the match.
       $exon_end = $proj_transcript_slice_length-($-[0]);
     } else {
say "strand is NOT -1";
       $exon_start = $-[0]+1; # +1 because exon coordinates start at 1 for Exon objects
       $exon_end = $+[0]+1-1; # +1 because exon coordinates start at 1 for Exon objects
                              # -1 because $+[] gives the index of the character following the match, not the last character of the match.
     }

say "ex seq: ".$exon_sequence;
say "exon_start: ".$exon_start;
say "exon_end: ".$exon_end;
say "exon_offset_from_start: ".$exon_offset_from_start;
say "original_proj_transcript_strand: ".$original_proj_transcript_strand;
say "proj_transcript_slice-seq:\n".$proj_transcript_slice->seq();
say "proj_transcript_slice-strand:\n".$proj_transcript_slice->strand();
    push(@projected_exons,
         new Bio::EnsEMBL::Exon(-START     => $exon_start,#+$exon_offset_from_start,#+$proj_transcript_slice->start(),
                                -END       => $exon_end,#-1,#+$exon_offset_from_start,#+$proj_transcript_slice->start(), # $+[] gives the index of the character following the match, not the last character of the match.
                                -STRAND    => 1, # the proj_transcript_slice is already on the reverse strand
                                -SLICE     => $proj_transcript_slice,
                                -ANALYSIS  => $source_transcript->analysis(),
                                -STABLE_ID => $source_transcript->stable_id_version(),
                                -VERSION   => 1));
  }

#  if ($original_proj_transcript_strand == -1) {
#    # the exon order is reversed 
#    @projected_exons = reverse(@projected_exons);
#  }

  my $projected_transcript = Bio::EnsEMBL::Transcript->new(-exons => \@projected_exons,
                                                           -analysis => $source_transcript->analysis(),
                                                           -stable_id => $source_transcript->stable_id_version(),
                                                           -strand => 1,#$original_proj_transcript_strand,
                                                           -slice => $proj_transcript_slice);
  
  say "projected_transcript slice name: ".$proj_transcript_slice->name;
  say "projected_transcript SID: ".$projected_transcript->stable_id;
  say "projected_transcript sr start: ".$projected_transcript->seq_region_start;
  say "projected_transcript sr end: ".$projected_transcript->seq_region_end;
  say "projected_transcript start: ".$projected_transcript->start;
  say "projected_transcript end: ".$projected_transcript->end;
  say "projected_transcript strand: ".$projected_transcript->strand;
  say "projected_transcript exon count: ".scalar(@projected_exons);

# DEBUG
foreach my $ex (@{$source_transcript->get_all_translateable_Exons()}) {
  say "source exon start: ".$ex->seq_region_start();
  say "source exon end: ".$ex->seq_region_end();
  say "source exon strand: ".$ex->seq_region_strand();
  say "source exon seq:\n".$ex->seq()->seq();
}

foreach my $ex (@{$projected_transcript->get_all_Exons()}) {
  say "projected exon start: ".$ex->seq_region_start();
  say "projected exon end: ".$ex->seq_region_end();
  say "projected exon strand: ".$ex->seq_region_strand();
  say "projected exon seq:\n".$ex->seq()->seq();
}

  my $translation = Bio::EnsEMBL::Translation->new();
  $translation->start_Exon($projected_exons[0]);
  $translation->start(1);
  $translation->end_Exon($projected_exons[-1]);
  $translation->end($projected_exons[-1]->length());
  $projected_transcript->translation($translation);

  # Set the phases  
  calculate_exon_phases($projected_transcript,$source_transcript->translation()->start_Exon()->phase());

  # Set the exon and transcript supporting features
  if ($projected_transcript->translation()->seq()) { 
    set_alignment_supporting_features($projected_transcript,$source_transcript->translation()->seq(),$projected_transcript->translation()->seq());
  }

  say "Transcript translation:\n".$source_transcript->translation()->seq();
  say "Projected transcript translation:\n".$projected_transcript->translation()->seq();

  my ($coverage,$percent_id) = (0,0);
  if ($projected_transcript->translation()->seq()) {
print("Projected transcript translation has a seq\n");
    ($coverage,$percent_id) = align_proteins($source_transcript->translate()->seq(),$projected_transcript->translate()->seq());
  }
say "pid high " if ($percent_id > 70);
  $projected_transcript->source($coverage);
  $projected_transcript->biotype($percent_id);
  $projected_transcript->description("stable_id of source: ".$source_transcript->stable_id());

  # add a 'seq_edits' attribute to the proj_exon object
  # to store the seq edits that will be added to the transcript
  # when the transcript is built
  #my @seq_edits = make_seq_edits($source_seq,$proj_seq);
  #$proj_exon->{'seq_edits'} = \@seq_edits;

  return ($projected_transcript);
}

#sub parse_exon {
#  my ($self,$source_exon,$projected_outfile_path) = @_;
#
#  
#
#  my $reference_exon_header = shift(@projection_array);
#  my $source_seq =  shift(@projection_array);
#  my $slice_name = shift(@projection_array);
#  my $proj_seq = shift(@projection_array);
#
#  if (scalar(@projection_array) > 0) {
#    $self->warning("Output file has more than one projection. The projection having fewer gaps will be chosen. Exon: ".$source_exon->stable_id);
#
#    # there are sometimes empty results which need to be skipped
#    chomp($source_seq);
#    chomp($proj_seq);
#    while (length($source_seq) <= 0 and length($proj_seq) <= 0) {
#      $reference_exon_header = shift(@projection_array);
#      $source_seq = shift(@projection_array);
#      $slice_name = shift(@projection_array);
#      $proj_seq = shift(@projection_array);
#      chomp($source_seq);
#      chomp($proj_seq);
#      printf("Chosen slice name $slice_name and projected sequence:\n$proj_seq due to empty results found before.\n");
#    }
#
#    my $next_reference_exon_header;
#    my $next_source_seq;
#    my $next_slice_name;
#    my $next_proj_seq;
#    while (scalar(@projection_array) > 0) {
#      $next_reference_exon_header = shift(@projection_array);
#      $next_source_seq = shift(@projection_array);
#      $next_slice_name = shift(@projection_array);
#      $next_proj_seq = shift(@projection_array);
#
#      chomp($next_proj_seq);
#      chomp($next_source_seq);
#      if (($next_proj_seq =~ tr/\-//) < ($proj_seq =~ tr/\-//) and
#          (length($source_seq) > 0) and (length($proj_seq) > 0)  
#         ) {
#        # if the number of gaps in the next projected sequence represented by the character '-'
#        # is lower than the current selection number of gaps then select the next projected sequence
#        # unless the next projected sequence is empty (it can happen)
#        $proj_seq = $next_proj_seq;
#        $slice_name = $next_slice_name;
#        $source_seq = $next_source_seq;
#        $reference_exon_header = $next_reference_exon_header;
#        printf("Chosen slice name $slice_name and projected sequence:\n$proj_seq\n");
#      }
#    }
#  }
#
#  unless($slice_name =~ /^>(.+\:.+\:.+\:)(.+)\:(.+)\:(.+)$/) {
#    $self->throw("Couldn't parse the header to get the slice name. Header: ".$slice_name);
#  }
#
#  my $proj_exon_slice_name = $1;
#  my $start_coord = $2;
#  my $end_coord = $3;
#  my $strand = $4;
#
#  # Reverse the strand if the slice of the source exon is on the negative strand (in these cases we have reverse complemented
#  # the slice sequence when projecting)
#  if($source_exon->strand == -1) {
#    $strand = $strand * -1;
#  }
#
#  say "FM2 EXON SLICE START: ".$start_coord;
#  say "FM2 EXON SLICE END: ".$end_coord;
#
#  $source_seq =~ /( *)([\-atgcnATGCN]+)( *)/;
#
#  my $source_left_flank = $1;
#  my $source_align = $2;
#  my $source_right_flank = $3;
#
#  say "FM2 LLF: ".length($source_left_flank);
#  say "FM2 LRF: ".length($source_right_flank);
#  if($strand == -1) {
#    $start_coord += length($source_right_flank);
#  } else {
#    $start_coord += length($source_left_flank);
#  }
#
#  if($strand == -1) {
#    $end_coord -= length($source_left_flank);
#  } else {
#    $end_coord -= length($source_right_flank);
#  }
#
#  say "FM2 START: ".$start_coord;
#  say "FM2 END: ".$end_coord;
#
#  $proj_exon_slice_name .= join(":",($start_coord,$end_coord,$strand));
#  my $slice_adaptor = $self->hrdb_get_con('target_dna_db')->get_SliceAdaptor();
#
#  my $proj_slice = $slice_adaptor->fetch_by_name($proj_exon_slice_name)->seq_region_Slice;
#  unless($proj_slice) {
#    $self->throw("Couldn't retrieve a slice for: ".$proj_exon_slice_name);
#  }
#
#  my $proj_exon;
#  if ($start_coord <= $end_coord+1) {
#    $proj_exon = new Bio::EnsEMBL::Exon(
#        -START     => $start_coord,
#        -END       => $end_coord,
#        -STRAND    => $strand,
#        -SLICE     => $proj_slice,
#        -ANALYSIS  => $source_exon->analysis,
#        -STABLE_ID => $source_exon->stable_id.".".$source_exon->version,
#        -VERSION   => 1,
#    );
#
#    # add a 'seq_edits' attribute to the proj_exon object
#    # to store the seq edits that will be added to the transcript
#    # when the transcript is built
#    #my @seq_edits = make_seq_edits($source_seq,$proj_seq);
#    #$proj_exon->{'seq_edits'} = \@seq_edits;
#  } else {
#    say "Start is not less than or equal to end+1. Exon skipped.";
#  }
#  return ($proj_exon);
#}

sub make_seq_edits {
  # It returns an array of SeqEdit objects for the target sequence to make
  # the insertions for the alignment gaps between the source and target sequences
  # created for an alignment between two dna sequence in cesar output format ie string containing acgtACGT-.
  # A SeqEdit object is added to the array for each substring of any number of "-" not multiple of 3.
  # Inserted bases are taken from the source sequence.

  my ($source_seq,$target_seq) = @_;

  my @seq_edits = ();
  my $acumm_gap_length = 0;
 
  # count the number of lowercase bases before the start of the actual (uppercase) target sequence
  my $num_lowercase_left_flank = 0;
  my $target_seq_copy = $target_seq;
  if ($target_seq_copy =~ m/([acgtn]+)[ACGTN-]+/g) {
    $num_lowercase_left_flank = length($1);
  }

  while ($target_seq =~ /(\-+)/g) {
    $acumm_gap_length += length($1);
    my $start = pos($target_seq)+1-$acumm_gap_length-$num_lowercase_left_flank;
    my $end = $start-1;

    push(@seq_edits,Bio::EnsEMBL::SeqEdit->new(-CODE    => '_rna_edit',
                                               -NAME    => 'rna_edit',
                                               -DESCRIPTION    => 'Cesar alignment',
                                               -START   => $start,
                                               -END     => $end,
                                               -ALT_SEQ => substr($source_seq,pos($target_seq)-length($1),length($1))
                                              ));
  }
  return (@seq_edits);
}

sub target_slices {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->param('_target_slices',$val);
  }

  unless($self->param_is_defined('_target_slices')) {
    $self->param('_target_slices',{});
  }

  return $self->param('_target_slices');
}

sub get_unique_translateable_transcripts {
  my ($self,$gene,$canonical) = @_;

  my $translateable_transcripts = {};
  if ($gene->biotype ne 'protein_coding') {
    $self->input_job->autoflow(0);
    $self->complete_early('Gene does not have protein_coding biotype!');
  }

  my @transcripts = ();
  if ($canonical) {
    push(@transcripts,$gene->canonical_transcript());
  } else {
    @transcripts = @{$gene->get_all_Transcripts()};
  }
  foreach my $transcript (@transcripts) {
    if ($transcript->biotype eq 'protein_coding') {
      my $dbid = $transcript->dbID();
      $translateable_transcripts->{$dbid} = $transcript;
    }
  }
  return(values(%{$translateable_transcripts}));
}

sub make_alignment_mapper {
  my ($self,$gen_al_blocks) = @_;

  my $FROM_CS_NAME = 'chromosome';
  my $TO_CS_NAME   = 'scaffold';

  my $mapper = Bio::EnsEMBL::Mapper->new($FROM_CS_NAME,
                                         $TO_CS_NAME);

  say "FM2 ALIGN MAP: ".ref($gen_al_blocks);
  foreach my $bl (@$gen_al_blocks) {
    foreach my $ugbl (@{$bl->get_all_ungapped_GenomicAlignBlocks}) {
      my ($from_bl) = $ugbl->reference_genomic_align;
      my ($to_bl)   = @{$ugbl->get_all_non_reference_genomic_aligns};

      say "FM2 from_bl: ".$from_bl->dnafrag_start.":".$from_bl->dnafrag_end;
      say "FM2 to_bl: ".$to_bl->dnafrag_start.":".$to_bl->dnafrag_end;
      $mapper->add_map_coordinates($from_bl->dnafrag->name,
                                   $from_bl->dnafrag_start,
                                   $from_bl->dnafrag_end,
                                   $from_bl->dnafrag_strand*$to_bl->dnafrag_strand,
                                   $to_bl->dnafrag->name,
                                   $to_bl->dnafrag_start,
                                   $to_bl->dnafrag_end);
    }
  }

  return $mapper;
}

sub parent_genes {
  my ($self,$val) = @_;
  if (!($self->param('_parent_genes'))) {
    $self->param('_parent_genes',[]);
  }

  if ($val) {
    push(@{$self->param('_parent_genes')},$val);
  }

  return $self->param('_parent_genes');
}

sub unique_translateable_transcripts {
  my ($self,$val) = @_;
  if (!($self->param('_unique_translateable_transcripts'))) {
    $self->param('_unique_translateable_transcripts',[]);
  }

  if ($val) {
    push(@{$self->param('_unique_translateable_transcripts')},$val);
  }

  return($self->param('_unique_translateable_transcripts'));
}

sub transcript_align_slices {
  my ($self,$val) = @_;
  if (!($self->param('_transcript_align_slices'))) {
    $self->param('_transcript_align_slices',[]);
  }

  if ($val) {
    push(@{$self->param('_transcript_align_slices')},$val);
  }

  return($self->param('_transcript_align_slices'));
}

sub output_genes {
  my ($self,$val) = @_;
  unless($self->param('_output_genes')) {
    $self->param('_output_genes',[]);
  }

  if($val) {
    push(@{$self->param('_output_genes')},$val);
  }

  return($self->param('_output_genes'));
}

sub files_to_delete {
  my ($self,$val) = @_;
  unless($self->param('_files_to_delete')) {
    $self->param('_files_to_delete',[]);
  }

  if($val) {
    push(@{$self->param('_files_to_delete')},$val);
  }

  return($self->param('_files_to_delete'));
}

sub remove_overlapping_exons {
# any exon overlapped by another longer exon is removed
# and it will not be part of the returned array reference of exons
  my ($exons) = shift;

  print("Removing overlapping projected exons... Before: ".scalar(@$exons)." exons.\n");

  my @discarded_exon_indexes = ();
  my $exon1_index = 0;
 
  foreach my $exon1 (@$exons) {
    my $exon2_index = 0;
    foreach my $exon2 (@$exons) {
      if ($exon1_index != $exon2_index and !($exon2_index ~~ @discarded_exon_indexes)) {
        if (features_overlap($exon1,$exon2)) {
          if ($exon1->length() <= $exon2->length()) {
            push(@discarded_exon_indexes,$exon1_index);
            last;
          }
        }
      }
      $exon2_index++;
    }
    $exon1_index++;
  }

  my $no_overlap_exons = [];
  my $exon_index = 0;
EXON: foreach my $exon (@$exons) {
    foreach my $discarded_exon_index (@discarded_exon_indexes) {
      if ($exon_index == $discarded_exon_index) {
        $exon_index++;
        next EXON;
      }
    }
    push(@{$no_overlap_exons},$exon);
    $exon_index++;
  }

  print("Removing overlapping projected exons... After: ".scalar(@{$no_overlap_exons})." exons.\n");

  return $no_overlap_exons;
}

####################################
# config variable holders
####################################
#
# transcript editing and filtering
#

sub TRANSCRIPT_FILTER {
   my ($self, $val) = @_;

  if (defined $val) {
    $self->param('TRANSCRIPT_FILTER',$val);
  }

  if ($self->param_is_defined('TRANSCRIPT_FILTER')) {
    return $self->param('TRANSCRIPT_FILTER');
  }
  else {
    return;
  }
}

sub filter {
  my ($self, $val) = @_;
  if ($val) {
    $self->param('_runnable_filter',$val);
  }

  # filter does not have to be defined, but if it is, it should
  # give details of an object and its parameters
  if ($self->TRANSCRIPT_FILTER and !$self->param_is_defined('_runnable_filter')) {
    if (not ref($self->TRANSCRIPT_FILTER) eq "HASH" or
        not exists($self->TRANSCRIPT_FILTER->{OBJECT}) or
        not exists($self->TRANSCRIPT_FILTER->{PARAMETERS})) {

      $self->throw("FILTER in config for '".$self->analysis->logic_name."' must be a hash ref with elements:\n" .
            "  OBJECT : qualified name of the filter module;\n" .
            "  PARAMETERS : anonymous hash of parameters to pass to the filter");
    } else {
      $self->require_module($self->TRANSCRIPT_FILTER->{OBJECT});
     
$self->filter($self->TRANSCRIPT_FILTER->{OBJECT}->new(%{$self->TRANSCRIPT_FILTER->{PARAMETERS}}));
    }
  }
  if ($self->param_is_defined('_runnable_filter')) {
    return $self->param('_runnable_filter');
  }
  else {
    return;
  }
}

1;
