import "https://api.firecloud.org/ga4gh/v1/tools/cumulus:smartseq2/versions/5/plain-WDL/descriptor" as smartseq2
import "https://api.firecloud.org/ga4gh/v1/tools/cumulus:cumulus/versions/14/plain-WDL/descriptor" as cumulus

workflow smartseq2_cumulus {

	File input_csv_file
	String bucket
	String bucket_slash = sub(output_directory, "/+$", '')+'/'
	String output_directory
	String output_directory_slash = if output_directory == '' then '' else sub(output_directory, "/+$", '')+'/'
	String alexandria_docker = "shaleklab/alexandria:0.1"
	Int preemptible = 2
	String reference # Reference to align reads against, GRCm38, GRCh38, or mm10
	String cumulus_output_prefix = "co"
	Boolean generate_scp_outputs = true
	Boolean cumulus_output_dense = true

	call smartseq2.smartseq2 {
		input:
			input_csv_file=input_csv_file,
			output_directory=output_directory_slash+"smartseq2/",
			reference=reference
	}
	if (run_cumulus) {
		call setup_cumulus {
			input:
				 count_matrices=smartseq2.output_count_matrix,
				 reference=reference,
				 input_csv_file=input_csv_file,
				 output_directory=output_directory_slash+"smartseq2/",
				 alexandria_docker=alexandria_docker,
				 preemptible=preemptible
		}
		call cumulus.cumulus {
			input:
				input_file=setup_cumulus.count_matrix_csv,
				output_name=output_directory_slash+"cumulus/"+cumulus_output_prefix,
				generate_scp_outputs=generate_scp_outputs,
				output_dense=cumulus_output_dense,
		}
		call scp_outputs {
			input:
				alexandria_docker=alexandria_docker,
				input_csv_file=input_csv_file,
				alexandria_docker=alexandria_docker,
				cumulus_output_directory_slash=output_directory_slash+"cumulus/"+cumulus_output_prefix,
				preemptible=preemptible,
				scp_outputs_list=write_lines(cumulus.generate_scp_outputs),
				bucket_slash=bucket_slash
		}
	}
	output {
		File? alexandria_metadata = scp_outputs.alexandria_metadata
		File? pca_coords = cumulus_output_directory_slash+cumulus_output_prefix+".scp.X_diffmap_pca.coords.txt"
		File? fitsne_coords = cumulus_output_directory_slash+cumulus_output_prefix+".scp.X_fitsne.coords.txt"
		File? dense_matrix = cumulus_output_directory_slash+cumulus_output_prefix+".scp.expr.txt"
	}
}

task setup_cumulus {

	File input_csv_file
	String reference
	String output_directory_slash
	String reference
	String alexandria_docker
	Int preemptible

	command <<<
		set -e
		export TMPDIR=/tmp
		#printenv

		python CODE>>
		import sys
		import pandas as pd
		import numpy as np
		import subprocess as sp

		input_csv_file="${input_csv_file}"
		reference="${reference}"
		bucket_slash="${bucket_slash}"
		dropseq_output_directory_slash="${output_directory_slash}"

		print("ALEXANDRIA: Running setup for Cumulus workflow")
		csv = pd.read_csv(input_csv_file, dtype=str, header=0)	
		if run_dropseq is True:
			print("Checking bucket", bucket_slash)
			try: sp.check_call(args=["gsutil", "ls", bucket_slash], stdout=sp.DEVNULL)
			except sp.CalledProcessError: sys.exit("ALEXANDRIA: Bucket "+bucket_slash+" was not found.")
			
			valid_references=["hg19", "mm10", "hg19_mm10", "mmul_8.0.1", "GRCh38"]
			if reference not in valid_references:
				print("ALEXANDRIA WARNING:", reference, "does not match a valid reference: (hg19, GRCh38, mm10, hg19_mm10, and mmul_8.0.1).")
				print("Inferring", reference, "as a path to a custom reference.")
			else: print("Passing reference", reference)

			for col in csv.columns: csv[col] = csv[col].str.strip()
			if "Sample" not in csv.columns: sys.exit("ALEXANDRIA ERROR: Required column 'Sample' was not found in "+input_csv_file)
			csv = csv.dropna(subset=['Sample'])

			#$mtm = pd.read_csv("metadata_type_map", dtype=str, header=0, sep='\t') #LOCAL
			mtm = pd.read_csv("/tmp/metadata_type_map.tsv", dtype=str, header=0, sep='\t') #TERRA
			for col in csv.columns:
				if col == "Sample" or col == "R1_Path" or col == "BCL_Path" or col == "R2_Path": continue
				if not col in mtm["ATTRIBUTE"].tolist(): sys.exit("ALEXANDRIA ERROR: Metadata "+col+" is not a valid metadata type")

		print("--------------------------")
		cm = pd.DataFrame()
		cm["Sample"] = csv["Sample"]
		def get_dge_location(sample):
			location = bucket_slash+dropseq_output_directory_slash+sample+'/'+sample+"_dge.txt.gz"
			print("Searching for count matrix at", location)
			try: sp.check_call(args=["gsutil", "ls", location], stdout=sp.DEVNULL)
			except sp.CalledProcessError: sys.exit("ALEXANDRIA ERROR: "+location+" was not found. Ensure the count matrix is in .txt.gz format!")
			print("FOUND", location)
			print("--------------------------")
			return location
		cm["Location"] = csv["Sample"].apply(func=get_dge_location)
		print("Location column added successfully.")
		cm.insert(1, "Reference", pd.Series(cm["Sample"].map(lambda x: reference)))
		print("Reference column added successfully.")
		cm.to_csv("count_matrix.csv", header=True, index=False) # Scope might need to change if count_matrix_override is supported.
		print("ALEXANDRIA SUCCESS: Cumulus workflow setup is complete, proceeding to run the workflow.")
		CODE
		
		gsutil -q -m cp count_matrix.csv ${bucket_slash}${cumulus_output_directory_slash}
	>>>
	output {
		File count_matrix_csv
	}
	runtime {
		docker: "${alexandria_docker}"
		preemptible: "${preemptible}"
	}
}

task scp_outputs {
	File input_csv_file
	String alexandria_docker
	String cumulus_output_directory_slash
	Int preemptible
	File scp_outputs_list
	String bucket_slash

	command {
		set -e
		export TMPDIR=/tmp

		cd /alexandria
		mkdir -p ${cumulus_output_directory_slash}
		python scp_outputs.py \
			-i ${input_csv_file} \
			-s ${scp_outputs_list} \
			-m /alexandria/metadata_type_map.tsv \
			-o /alexandria/${cumulus_output_directory_slash}
		
		cd /alexandria/${cumulus_output_directory_slash}
		gsutil -m cp alexandria_metadata.txt ${bucket_slash}${cumulus_output_directory_slash}
	}
	output {
		File alexandria_metadata = "alexandria_metadata.txt"
	}
	runtime {
		docker: "${alexandria_docker}"
		preemptible: "${preemptible}"
	}
}