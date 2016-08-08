
open Nonstd
module String = Sosa.Native_string

let indel_realigner_config =
  let open Biokepi.Tools.Gatk.Configuration in
  (* We need to ignore reads with no quality scores that BWA includes in the
     BAM, but the GATK's Indel Realigner chokes on (even though the reads are
     unmapped).

     cf. http://gatkforums.broadinstitute.org/discussion/1429/error-bam-file-has-a-read-with-mismatching-number-of-bases-and-base-qualities *)
  let indel_cfg = {
    Indel_realigner.
    name = "ignore-mismatch";
    filter_reads_with_n_cigar = true;
    filter_mismatching_base_and_quals = true;
    filter_bases_not_stored = true;
    parameters = [] }
  in
  let target_cfg = {
    Realigner_target_creator.
    name = "ignore-mismatch";
    filter_reads_with_n_cigar = true;
    filter_mismatching_base_and_quals = true;
    filter_bases_not_stored = true;
    parameters = [] }
  in
  (indel_cfg, target_cfg)

let star_config =
  let open Biokepi.Tools.Star.Configuration.Align in
  {
    name = "mapq_default_60";
    parameters = [];
    (* Cf. https://www.broadinstitute.org/gatk/guide/article?id=3891

    In particular:

       STAR assigns good alignments a MAPQ of 255 (which technically means
       “unknown” and is therefore meaningless to GATK). So we use the GATK’s
       ReassignOneMappingQuality read filter to reassign all good alignments to the
       default value of 60.
    *)
    sam_mapq_unique = Some 60;
    overhang_length = None;
  }


let strelka_config = Biokepi.Tools.Strelka.Configuration.exome_default
let mutect_config = Biokepi.Tools.Mutect.Configuration.default_without_cosmic

let mark_dups_config =
  Biokepi.Tools.Picard.Mark_duplicates_settings.default


module Parameters = struct

  type t = {
    with_seq2hla: bool [@default false];
    with_topiary: string list option;
    with_mutect2: bool [@default false];
    with_varscan: bool [@default false];
    with_somaticsniper: bool [@default false];
    experiment_name: string [@main];
    (* run_name: string [@main]; *)
    reference_build: string;
    normal: Biokepi.EDSL.Library.Input.t;
    tumor: Biokepi.EDSL.Library.Input.t;
    rna: Biokepi.EDSL.Library.Input.t option;
  } [@@deriving show,make]

  let construct_run_name params =
    let {normal;  tumor; rna; experiment_name; reference_build; _} = params in
    let name_of_input i =
      let open Biokepi.EDSL.Library.Input in
      match i with
      | Fastq { sample_name; _ } -> sample_name
    in
    String.concat ~sep:"-" [
      experiment_name;
      name_of_input normal;
      name_of_input tumor;
      Option.value_map ~f:name_of_input rna ~default:"noRNA";
      reference_build;
    ]

  (* To maximize sharing the run-directory depends only on the
     experiement name (to allow the use to force a fresh one) and the
     reference-build (since Biokepi does not track it yet in the filenames). *)
  let construct_run_directory param =
    sprintf "%s-%s" param.experiment_name param.reference_build


  let input_to_string t =
    let open Biokepi.EDSL.Library.Input in
    let fragment =
      function
      | (_, PE (r1, r2)) -> sprintf "Paired-end FASTQ"
      | (_, SE r) -> sprintf "Single-end FASTQ"
      | (_, Of_bam (`SE,_,_, p)) -> "Single-end-from-bam"
      | (_, Of_bam (`PE,_,_, p)) -> "Paired-end-from-bam"
    in
    let same_kind a b =
      match a, b with
      | (_, PE _)              , (_, PE _)               -> true
      | (_, SE _)              , (_, SE _)               -> true
      | (_, Of_bam (`SE,_,_,_)), (_, Of_bam (`SE,_,_,_)) -> true
      | (_, Of_bam (`PE,_,_,_)), (_, Of_bam (`PE,_,_,_)) -> true
      | _, _ -> false
    in
    match t with
    | Fastq { sample_name; files } ->
      sprintf "%s, %s"
        sample_name
        begin match files with
        | [] -> "NONE"
        | [one] ->
          sprintf "1 fragment: %s" (fragment one)
        | one :: more ->
          sprintf "%d fragments: %s"
            (List.length more + 1)
            (if List.for_all more ~f:(fun f -> same_kind f one)
             then "all " ^ (fragment one)
             else "heterogeneous")
        end

  let metadata t = [
    "Topiary",
    begin match t.with_topiary  with
    | None  -> "Not used"
    | Some l -> sprintf "Called with alleles: [%s]"
                  (String.concat l ~sep:"; ")
    end;
    "Reference-build", t.reference_build;
    "Normal-input", input_to_string t.normal;
    "Tumor-input", input_to_string t.tumor;
    "RNA-input", Option.value_map ~default:"N/A" ~f:input_to_string t.rna;
  ]

end


module Full (Bfx: Extended_edsl.Semantics) = struct

  module Stdlib = Biokepi.EDSL.Library.Make(Bfx)

  let align ~reference_build ~aligner (fastqs : [`Fastq] list Bfx.repr) =
    Bfx.list_map fastqs
      ~f:(Bfx.lambda (fun fq -> aligner ~reference_build fq))

  let to_bam ~reference_build fq =
    align ~reference_build fq ~aligner:(Bfx.bwa_mem ?configuration:None)
    |> Bfx.merge_bams
    |> Bfx.picard_mark_duplicates
      ~configuration:mark_dups_config

  let final_bams ~normal ~tumor =
    let pair =
      Bfx.pair normal tumor
      |> Bfx.gatk_indel_realigner_joint
        ~configuration:indel_realigner_config
    in
    Bfx.gatk_bqsr (Bfx.pair_first pair), Bfx.gatk_bqsr (Bfx.pair_second pair)


  let vcfs
      ~with_mutect2
      ~with_varscan
      ~with_somaticsniper
      ~reference_build ~normal ~tumor =
    [
      "strelka", Bfx.strelka () ~normal ~tumor ~configuration:strelka_config;
      "mutect", Bfx.mutect () ~normal ~tumor ~configuration:mutect_config;
      "haplo-normal", Bfx.gatk_haplotype_caller normal;
      "haplo-tumor", Bfx.gatk_haplotype_caller tumor;
    ]
    @ (if with_mutect2 then ["mutect2", Bfx.mutect2 ~normal ~tumor ()] else [])
    @ (if with_varscan then ["varscan", Bfx.varscan_somatic ~normal ~tumor ()] else [])
    @ (if with_somaticsniper
       then ["somatic-sniper", Bfx.somaticsniper ~normal ~tumor ()]
       else [])

  let qc fqs =
    Bfx.concat fqs |> Bfx.fastqc

  let rna_bam ~reference_build fqs =
    align ~reference_build fqs ~aligner:(Bfx.star ~configuration:star_config)
    |> Bfx.merge_bams
    |> Bfx.picard_mark_duplicates
      ~configuration:mark_dups_config
    |> Bfx.gatk_indel_realigner
      ~configuration:indel_realigner_config

  let hla fqs =
    Bfx.seq2hla (Bfx.concat fqs)

  let ( *** ) a b  = Bfx.pair a b |> Bfx.to_unit

  let rna_pipeline ~reference_build ~somatic_vcf fqs =
    let bam = rna_bam ~reference_build fqs in
    let isovared =
      Bfx.isovar
        reference_build
        somatic_vcf
        bam in
    (
      Some (bam |> Bfx.save "rna-bam"),
      Some (bam |> Bfx.stringtie |> Bfx.save "stringtie"),
      Some (isovared |> Bfx.save "isovar"),
      (* Seq2HLA does not work on mice: *)
      (match reference_build with
      | "mm10" -> None
      | _ -> Some (hla fqs)),
      Some (bam |> Bfx.flagstat |> Bfx.save "rna-bam-flagstat")
    )

  let run parameters =
    let open Parameters in
    let normal = Stdlib.fastq_of_input parameters.normal in
    let tumor = Stdlib.fastq_of_input parameters.tumor in
    let rna = Option.map parameters.rna ~f:Stdlib.fastq_of_input in
    let normal_bam, tumor_bam =
      final_bams
        ~normal:(normal |> to_bam ~reference_build:parameters.reference_build)
        ~tumor:(tumor |> to_bam ~reference_build:parameters.reference_build)
      |> (fun (n, t) -> Bfx.save "normal-bam" n, Bfx.save "tumor-bam" t)
    in
    let normal_bam_flagstat, tumor_bam_flagstat =
      Bfx.flagstat normal_bam |> Bfx.save "normal-bam-flagstat",
      Bfx.flagstat tumor_bam |> Bfx.save "tumor-bam-flagstat"
    in
    let vcfs =
      let {with_mutect2; with_varscan; with_somaticsniper; _} = parameters in
      vcfs
        ~with_mutect2
        ~with_varscan
        ~with_somaticsniper
        ~reference_build:parameters.reference_build
        ~normal:normal_bam ~tumor:tumor_bam in
    let somatic_vcf = List.hd_exn vcfs |> snd in
    let rna_bam, stringtie, isovar, seq2hla, rna_bam_flagstat =
      match rna with
      | None -> None, None, None, None, None
      | Some r ->
        rna_pipeline r ~reference_build:parameters.reference_build ~somatic_vcf
    in
    let maybe_annotated =
      match parameters.reference_build with
      | "b37" | "hg19" ->
        List.map vcfs ~f:(fun (k, vcf) ->
            Bfx.vcf_annotate_polyphen parameters.reference_build vcf
            |> fun a -> (k, Bfx.save ("VCF-annotated-" ^ k) a))
      | _ -> vcfs
    in
    let topiary =
      Option.map parameters.with_topiary ~f:(fun alleles ->
          Bfx.topiary
            parameters.reference_build
            somatic_vcf
            `Random
            (Bfx.mhc_alleles (`Names alleles))
          |> Bfx.save "Topiary"
        ) in
    let seq2hla = if not parameters.with_seq2hla then None else seq2hla in
    let vaxrank =
      let open Option in
      parameters.with_topiary
      >>= fun alleles ->
      rna_bam
      >>= fun bam ->
      return (
        Bfx.vaxrank
          parameters.reference_build
          somatic_vcf
          bam
          `Random
          (Bfx.mhc_alleles (`Names alleles))
        |> Bfx.save "Vaxrank"
      ) in
    Bfx.observe (fun () ->
        Bfx.report
          (Parameters.construct_run_name parameters)
          ~vcfs:maybe_annotated
          ~qc_normal:(qc normal |> Bfx.save "QC:normal")
          ~qc_tumor:(qc tumor |> Bfx.save "QC:tumor")
          ~normal_bam ~tumor_bam ?rna_bam
          ~normal_bam_flagstat ~tumor_bam_flagstat
          ?vaxrank ?topiary ?isovar ?seq2hla ?stringtie ?rna_bam_flagstat
          ~metadata:(Parameters.metadata parameters)
      )


end