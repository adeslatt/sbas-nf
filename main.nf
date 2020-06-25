/*
 * Copyright (c) 2020, The Jackson Laboratory and the authors.
 *
 *   This file is part of TheJacksonLaboratory/sbas repository.
 *
 * Main TheJacksonLaboratory/sbas pipeline script for post rmats differential splicing analysis
 *
 * @authors
 * Name1 LastName1 <name.lastname1@email.com>
 * Name2 LastName2 <name.lastname2@email.com>
 */

log.info "Post-rmats differential splicing analysis version 0.1"
log.info "====================================="
log.info "Tissue table .csv : ${params.tissues_csv}"
log.info "Input notebook    : ${params.notebook}"
log.info "../data/ tar.gz   : ${params.data}"
log.info "../assets/ tar.gz : ${params.assets}"
log.info "Results directory : ${params.output}"
log.info "\n"

def helpMessage() {
    log.info """
    Usage:
    The typical command for running the pipeline is as follows:
    nextflow run cgpu/sbas-nf --tissues_csv file1 --notebook gs://my_R_notebook.ipynb --data gs://data.tar.gz --assets gs://assets.tar.gz -profile docker
    Mandatory arguments:
      --tissues_csv             Path to input file. The suffix of the file must be .csv
                                The csv file is expected to have two columns with header
                                Column 1, must be a numeric index of the row
                                Column 2, must correspond to the name of the tissue
                                The order is expected to be the same as the output of the command:
                                `levels(reduced_metadata_pData$tissue)`

      --notebook                The path to the .ipynb notebook that is to be executed
      --data                    The path to the .tar.gz archive that contains all the files used as input by the notebook from the ../data folder.
                                It is expected that upon decompressing the archive with the command `tar xvzf data.tar.gz -C ../data`
                                all input files will be in the required format for the notebook to run,
                                eg. flat file structure, and not nested in another folder.
      --assets                  The path to the .tar.gz archive that contains all the files used as input by the notebook from the ../assets folder.
                                It is expected that upon decompressing the archive with the command `tar xvzf data.tar.gz -C ../assets`
                                all input files will be in the required format for the notebook to run,
                                eg. flat file structure, and not nested in another folder.
      -profile                  Configuration profile to use. Can use multiple (comma separated)
                                Available: testdata, docker, ...
    Optional:
      --output                  Path to output directory.
                                Default: 'results'

      --ontologizer             [No value]
                                Switch flag, pass to enable the execution of the optional
                                Ontologizer process on the gene lists generated by the runNotebook process.

      --gaf                     Path to GO Annotation file. The suffix must be .gaf
                                Conditionally required when '--ontologizer' is set.

      --obo                     Path to GO ontology in obo format. The suffix muste be .obo
                                Conditionally required when '--ontologizer' is set.

    """.stripIndent()
}

/*********************************
 *      CHANNELS SETUP           *
 *********************************/

// Helper variables
alternativeSplicingTypeList = ['a3ss', 'a5ss', 'mxe', 'ri', 'se']
junctionCountTypeList       = ['jc','jcec']
countingTypeList            = ['ijc','sjc','inc','inclen','skiplen']

// Input files

ch_notebook = Channel.fromPath(params.notebook, checkIfExists: true)
ch_data = Channel.fromPath(params.data, checkIfExists: true)
ch_assets = Channel.fromPath(params.assets, checkIfExists: true)

// Optional Ontologizer input files

ch_obo_file = params.ontologizer ? Channel.fromPath(params.obo, checkIfExists: true) :  Channel.empty()
ch_go_annotation_file = params.ontologizer ?  Channel.fromPath(params.gaf, checkIfExists: true) :  Channel.empty()

// Input list .csv file of tissues to analyse
if (params.tissues_csv.endsWith(".csv")) {
  Channel.fromPath(params.tissues_csv)
                        .ifEmpty { exit 1, "Input .csv list of input tissues not found at ${params.tissues_csv}. Is the file path correct?" }
                        .splitCsv(sep: ',',  header: true)
                        .set { ch_tissues_indices }
  }

/*********************************
 *          PROCESSES            *
 *********************************/

/*
 * Execute the notebook for each tissue
 */

 process runNotebook {
    machineType 'n1-standard-16'
    tag "${tissue_index}-${tissue_name}"
    publishDir "results/differential/per_tissue/${tissue_name}/"
    publishDir "results/differential/all_tissues/"

    input:
    set val(tissue_index), val(tissue_name) from ch_tissues_indices
    each file(notebook) from ch_notebook
    each file(data) from ch_data
    each file(assets) from ch_assets

    output:
    set val(tissue_name), val('a3ss'), file("data/a3ss*${params.model}_gene_set.txt"), file("data/a3ss*${params.model}_universe.txt") into ch_ontologizer_a3ss
    set val(tissue_name), val('a5ss'), file("data/a5ss*${params.model}_gene_set.txt"), file("data/a5ss*${params.model}_universe.txt") into ch_ontologizer_a5ss
    set val(tissue_name), val('mxe'),  file("data/mxe*${params.model}_gene_set.txt"),  file("data/mxe*${params.model}_universe.txt")  into ch_ontologizer_mxe
    set val(tissue_name), val('ri'),   file("data/ri*${params.model}_gene_set.txt"),   file("data/ri*${params.model}_universe.txt")   into ch_ontologizer_ri
    set val(tissue_name), val('se'),   file("data/se*${params.model}_gene_set.txt"),   file("data/se*${params.model}_universe.txt")   into ch_ontologizer_se
    set val(tissue_name), val('all_as_types'), file("data/*${params.model}*_universe.txt"), file("data/*${params.model}*_gene_set.txt") into ch_all_as_types_ontol_inputs
    file "data/*csv"
    file "pdf/"
    file "metadata/"
    file "assets/"
    file "jupyter/${tissue_name}_diff_splicing.ipynb"

    script:
    """
    mkdir -p jupyter
    mkdir -p data
    mkdir -p pdf
    mkdir -p metadata
    mkdir -p assets

    tar xvzf $data -C data/
    tar xvzf $assets -C assets/

    cp $notebook jupyter/main.ipynb
    cd jupyter

    papermill main.ipynb ${tissue_name}_diff_splicing.ipynb -p tissue_index $tissue_index
    """
}


/*
 * Create combined gene_set and universe from union of AS types for Ontologizer
 */

 process createAStypeUnions {
    tag "${tissue}-${as_type}"
    publishDir "results/AStypeUnions"
    echo true

    input:
    set  val(tissue), val(as_type), file(gene_set), file(universe) from ch_all_as_types_ontol_inputs

    output:
    set  val(tissue), val(as_type), file("${as_type}_${tissue}_${params.model}_gene_set.txt"), file("${as_type}_${tissue}_${params.model}_universe.txt") into ch_ontologizer_combined_as

    when:  params.ontologizer

    script:
    """
    ls *.* | grep $tissue | grep universe | grep ${params.model} | xargs cat | sort | uniq > ${as_type}_${tissue}_${params.model}_universe.txt
    ls *.* | grep $tissue | grep gene_set | grep ${params.model} | xargs cat | sort | uniq > ${as_type}_${tissue}_${params.model}_gene_set.txt
    ls -l *
    """
}

ch_ontologizer = ch_ontologizer_a3ss.concat(ch_ontologizer_a5ss, ch_ontologizer_mxe, ch_ontologizer_ri, ch_ontologizer_se, ch_ontologizer_combined_as)

/*
 * Perform Gene Ontology analysis with Ontologizer
 */

 process ontologizer {
    tag "${tissue}-${as_type}"
    label 'ontologizer'
    publishDir "results/ontologizer/${as_type}"

    input:
    set  val(tissue), val(as_type), file(gene_set), file(universe) from ch_ontologizer
    each file(go_obo) from ch_obo_file
    each file(goa_human_gaf) from ch_go_annotation_file

    output:
    file("view*.txt") into ch_ontologizer_dag
    file("table*.txt") into ch_ontologizer_table
    file("anno*.txt") into ch_ontologizer_anno

    when:  params.ontologizer

    script:
    """
    ontologizer \
    --studyset $gene_set \
    --population $universe \
    --go $go_obo \
    --association $goa_human_gaf \
    --calculation Term-For-Term \
    --mtc Benjamini-Hochberg \
    --outdir ${tissue} \
    --annotation \
    --dot \
    """
}

 process createArchives {
    label 'ontologizer'
    publishDir "results/ontologizer/archives/"

    input:
    file(dot) from ch_ontologizer_dag.collect()
    file(table) from ch_ontologizer_table.collect()
    file(anno) from ch_ontologizer_anno.collect()

    output:
    file("*.tar.gz")

    when:  params.ontologizer

    script:
    """
    # se
    tar cvzf view-se.tar.gz view-se*
    tar cvzf anno-se.tar.gz anno-se*
    tar cvzf table-se.tar.gz table-se*

    # a3ss
    tar cvzf view-a3ss.tar.gz view-a3ss*
    tar cvzf anno-a3ss.tar.gz anno-a3ss*
    tar cvzf table-a3ss.tar.gz table-a3ss*

    # a5ss
    tar cvzf view-a5ss.tar.gz view-a5ss*
    tar cvzf anno-a5ss.tar.gz anno-a5ss*
    tar cvzf table-a5ss.tar.gz table-a5ss*

    # mxe
    tar cvzf view-mxe.tar.gz view-mxe*
    tar cvzf anno-mxe.tar.gz anno-mxe*
    tar cvzf table-mxe.tar.gz table-mxe*

    # ri
    tar cvzf view-ri.tar.gz view-ri*
    tar cvzf anno-ri.tar.gz anno-ri*
    tar cvzf table-ri.tar.gz table-ri*

    # all_as_types
    tar cvzf view-all_as_types.tar.gz view-all_as_types*
    tar cvzf anno-all_as_types.tar.gz table-all_as_types*
    tar cvzf table-all_as_types.tar.gz table-all_as_types*
    """
}
