#!/bin/bash
# Script-version of http://blog.konradvoelkel.de/2013/03/scan-to-pdfa/
#
# Author: Carsten Rösnick <carsten@caero.de>
#                         <roesnick@mathematik.tu-darmstadt.de>
# Requirements:
# - convert (imagemagick)
# - unpaper
# - tesseract-ocr
# - hocr2pdf (exactimage)
# - pdfjam

dpi=300
in_pattern=".*.(tif|tiff|pdf)"
out_name="book-ocr.pdf"
# Without trailing '/'!
built_dir=".book"

while getopts :i:o:d:h option
do
	case $option in
		i)
			in_pattern=$OPTARG
			;;
		o)
			out_name=$OPTARG
			;;
		d)
			dpi=$OPTARG
			;;
		h)
			echo "Usage:"
			echo "-d dpi      : Integer value; DPI to process all files with."\
				"Default: 300."
			echo "-i pattern  : Pattern matching the scanned pages that should"\
				"be processed. Default: '.*.(tif|tiff|pdf)'."
			echo "-o filename : How should the final PDF be called?"\
				"Default: 'book-ocr.pdf'."
			exit 0
			;;
	esac
done

# Helper functions
_file_base () {
	basename $1 | sed 's/\.[[:alpha:]]\+$//g'
}
_file_suffix () {
	basename $1 | sed 's/.*\.\([[:alpha:]]\+$\)/\1/'
}

# TODO Check if book exists
echo "Creating built-directory '${built_dir}'."
mkdir $built_dir

echo "Converting files to single-paged tifs (if necessary)."
echo "-----------------------------------------------------"
for file in $(find . -maxdepth 1 -type f -regextype posix-awk -regex "$in_pattern")
do
	file_base=$(_file_base $file)
	# File extension in lower-case
	file_ext=$(_file_suffix $file | tr '[A-Z]' '[a-z]')

	if [ $file_ext == "tif" ]
	then
		echo "${file_base}.tif : Fine; simply copy it."
		cp $file "./${built_dir}/$(basename $file)"
	fi

	if [ $file_ext == "pdf" ]
	then
		echo "${file_base}.pdf : 'pdf'; Converting it into 'tif'."
		# This is the only place where the script MIGHT get killed.
		# Reason: convert regularly gets killed when fed with 'pdf's with too
		# many pages + HIGH DENSITY (DPI) option.
		# TODO
		# Find a way to get around this problem. Maybe try to convert
		# one page after another to 'tif'.
		convert \
			-density $dpi \
			$file "./${built_dir}/$file_base.tif"
		file_ext="tif"
	fi

	if [ $file_ext == "tiff" ]
	then
		echo "$file : Okay; rename it to 'tif'."
		cp $file "./${built_dir}/$file_base.tif"
	fi

	cd $built_dir

	file_type=$(tiffinfo "$file_base.tif" | grep -c ^TIFF)
	if [ $file_type -gt 1 ]
	then
		echo "$file_base.tif is multi-paged. Start splitting them up into"\
			"consecutive single-paged 'tif's."
		tiffsplit "$file_base.tif" $file_base
		rm "$file_base.tif"
	elif [ $file_type == 0 ]
	then
		echo "ERROR: Expected a TIF-file as the first argument"\
			"($(basename $file) is none)."
		# Cleanup
		cd ..
		rm -Rf "./$built_dir"
		exit 1
	fi

	cd ..
done

cd $built_dir

echo "Starting the real post-processing."
echo "----------------------------------"
for file in ./*
do
	file_base=$(_file_base $file)

	# Pre-processing.
	# Unpaper works on 'pbm's, so we first convert the 'tif's accordingly.
	echo "${file_base}.tif : 'tif' -> 'pbm'"
	convert \
		-density $dpi \
		"$file" "$file_base.pbm"

	# Determine page type: portrait, landscape or unknown
	# Heuristic: Ratio width : height
	# >= 1.2     -> portait, so presumably single-paged
	#            -> pagetype := -1
	# <= 0.8     -> landscape, so presumably double-paged
	#            -> pagetype :=  1
	# in between -> print warning and ASSUME landscape
	#            -> pagetype :=  0
	page_type=$(
		tiffinfo "$file" |
		grep ".*Image Width.*" |
		sed 's/^[[:blank:]]*Image Width: \([0-9]*\) Image Length: \([0-9]*\).*/\1,\2/' |
		awk '{
			split($0,a,",");
			mode=a[2]/a[1];
			print(mode<=0.8 ? 1 : (mode>=1.2 ? -1 : 0)); }')
	# default initialization
	unpaper_layout="--layout double --output-pages 2"
	unpaper_outpages="${file_base}-A.pbm ${file_base}-B.pbm"

	case $page_type in
		1)
			echo "${file_base}.tif in landscape mode, assuming it to be"\
				"double-paged."
			;;
		-1)
			unpaper_layout="--layout single --output-pages 1"
			unpaper_outpages="${file_base}-A.pbm"
			echo "${file_base}.tif in portrait mode, assuming it to be"\
				"single-paged."
			;;
		0)
			echo "WARNING: ${file_base}.tif has ambiguous orientation."\
				"Assuming it to be double-paged."
			;;
	esac

	# Split, crop, rotate and color-modify the scanned pages
	echo "${file_base}.pbm : Calling unpaper."
	unpaper --dpi $dpi --type pbm --input-pages 1 $unpaper_layout \
		"${file_base}.pbm" $unpaper_outpages 1> /dev/null
	rm "${file_base}.pbm"

	for page in $(find . -type f -regex ".*-[A|B].pbm")
	do
		page_base=$(_file_base $page)
		echo "${page_base}.pbm : Convert to normalized 'png' for tesseract."
		convert \
			-normalize \
			-density $dpi \
			-quality 100 \
			-depth 8 \
			"$page" "normal-${page_base}.png"
		rm "$page"

		echo "${page_base}.png : Calling tesseract to produce OCR metadata."
		tesseract -l eng -psm 1 \
			"normal-${page_base}.png" "${page_base}.pdf" hocr \
			> /dev/null 2> /dev/null

		# Combine original file with OCR data
		echo "normal-${page_base}.png : 'png' -> 'jpg' for final enrichment"\
			"with OCR metadata."
		convert \
			-density $dpi \
			-quality 100 \
			"normal-${page_base}.png" "normal-${page_base}.jpg"
		rm "normal-${page_base}.png"

		echo "normal-${page_base}.jpg : hocr2pdf; combine image and OCR"\
			"metadata."
		# Suppress bugging -- and wrong! -- XML-validity warning
		hocr2pdf \
			-i "normal-${page_base}.jpg" \
			-s \
			-o "${page_base}.pdf" < "${page_base}.pdf.html" 2> /dev/null
		rm "normal-${page_base}.jpg"
		rm "${page_base}.pdf.html"
	done
done

echo "Joining all single-paged 'pdf's."
# Do NOT use pdfjoin: it calls pdfjoin with --rotateoversize, causing
# some of the pages to be rotated in the final PDF.
pdfjam *.pdf > /dev/null 2> /dev/null
mv *-pdfjam.pdf "../$out_name"
cd .. && rm -Rf "$built_dir"

echo "DONE."
