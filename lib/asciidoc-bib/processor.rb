#
# Manage the current set of citations, the document settings, and 
# and main operations.
#

module AsciidocBib

  # Class used through utility method to hold data about citations for 
  # current document, and run the different steps to add the citations 
  # and bibliography
  class Processor
    include ProcessorUtils

    # Top-level method to include citations in given asciidoc file
    def Processor.run filename, bibfile, links, style
      processor = Processor.new BibTeX.open(bibfile), links, style
      processor.read_filenames filename
      processor.read_citations 
      processor.add_citations
    end

    attr_reader :biblio, :links, :style, :citations

    def initialize biblio, links, style
      @biblio = biblio
      @links = links
      @style = style
      @citations = Citations.new
      @filenames = Set.new
    end

    # Given an asciidoc filename, reads in all dependent files based on 'include::' statements
    # Leaving a list of files in @filenames
    def read_filenames filename
      puts "Reading file: #{filename}"
      files_to_process = [filename]

      begin
        @filenames.add files_to_process.first
        File.new(files_to_process.shift).each_line do |line|
          if line.include?("include::")
            line.split("include::").drop(1).each do |filetxt|
              file = File.expand_path(filetxt.partition(/\s|\[/).first)
                files_to_process << file unless @filenames.include?(file)
            end
          end
        end
      end until files_to_process.empty?
    end

    # Scans each filename and extracts citations
    def read_citations 
      @filenames.each do |file|
        IO.foreach(file) do |line|
          @citations.add_from_line line
        end
      end 
    end

    # Read given text to add cites and biblio to a new file
    # Order is always decided by author surname first with year.
    # If no author present, then use editor field.
    # Links indicates if internal links to be added.
    # Assumes @filenames has been set to list of filenames to process.
    def add_citations 
      @filenames.each do |curr_file|
        ref_filename = FileUtils.add_ref(curr_file)
        puts "Writing file:	#{ref_filename}"
        output = File.new(ref_filename, "w")

        IO.foreach(curr_file) do |line|
          begin # catch any errors, and ensure the lines of text are written
            line.strip! 
            case 
            when line.include?('include::')
              output_include_line output, line
            when line.include?('[bibliography]')
              output_bibliography output
            else
              output_cite_completed_line output, line
            end
          rescue # Any errors, just output the line
            output.puts line
          end
        end

        output.close
      end 
    end

    # Output bibliography to given output
    def output_bibliography output
      @citations.sorted_cites(@biblio).each do |ref|
        output.puts get_reference(ref)
        output.puts
      end
    end

    def output_include_line output, line
      line.split("include::").drop(1).each do |filetxt|
        ifile = filetxt.partition(/\s|\[/).first
        file = File.expand_path ifile 
        # make sure included file points to the -ref version
        line.gsub!("include::#{ifile}", "include::#{FileUtils.add_ref(file)}")
      end
      output.puts line
    end

    # For each citation in given line, expand into complete citation text
    # before outputting the line
    def output_cite_completed_line output, line
      @citations.retrieve_citations(line).each do |citation|
        line.gsub!(citation.original, complete_citation(citation))
      end
      output.puts line
    end

    # Return the complete citation text for given cite_data
    def complete_citation cite_data
      result = ''
      ob, cb = '(', ')'

      cite_data.cites.each_with_index do |cite, index|
        # before all items apart from the first, insert appropriate separator
        result << "#{separator} " unless index.zero?

        # @links requires adding hyperlink to reference
        result << "<<#{cite.ref}," if @links

        # if found, insert reference information
        unless biblio[cite.ref].nil?
          item = biblio[cite.ref].clone
          item['citation-number'] = @citations.cites_used.index(cite.ref) + 1
          cite_text, ob, cb = make_citation item, cite_data, cite
        else
          puts "Unknown reference: #{cite.ref}"
          cite_text = "#{cite.ref}"
        end

        result << cite_text.html_to_asciidoc
        # @links requires finish hyperlink
        result << ">>" if @links
      end

      unless @links
        # combine numeric ranges
        if Styles.is_numeric? @style
          result = combine_consecutive_numbers result
        end
      end

      include_pretext result, cite_data, ob, cb
    end

    # Retrieve text for reference in given style
    # - ref is reference for item to give reference for
    def get_reference ref
      result = ""
      result << ". " if Styles.is_numeric? @style

      item = @biblio[ref]
      item = item.convert_latex unless item.nil?

      result << "[[#{ref}]]" if @links
      return result+ref if item.nil?

      cptext = CiteProc.process item.to_citeproc, :style => @style, :format => :html
      result << cptext unless cptext.nil?

      return result.html_to_asciidoc
    end

    def separator
      if Styles.is_numeric? @style
        ','
      else
        ';'
      end
    end

    # Format pages with pp/p as appropriate
    def with_pp pages
      return '' if pages.empty?

      if @style.include? "chicago"
        pages
      elsif pages.include? '-'
        "pp.&#160;#{pages}"
      else
        "p.&#160;#{pages}"
      end
    end

    # Return page string for given cite
    def page_str cite
      result = ''
      unless cite.pages.empty?
        result << "," unless Styles.is_numeric? @style
        result << " #{with_pp(cite.pages)}"
      end

      return result
    end

    def include_pretext result, cite_data, ob, cb
      pretext = cite_data.pretext
      pretext += ' ' unless pretext.empty? # add space after any content

      if Styles.is_numeric? @style
        "#{pretext}#{ob}#{result}#{cb}"
      elsif cite_data.type == "cite" 
        "#{ob}#{pretext}#{result}#{cb}"
      else 
        "#{pretext}#{result}"
      end
    end

    def make_citation item, cite_data, cite
      cite_text = CiteProc.process item.to_citeproc, :style => @style, :format => :html, :mode => 'citation'
      cite_text = cite_text[0]

      fc = cite_text[0,1]
      lc = cite_text[-1,1]
      cite_text = cite_text[1..-2]

      if Styles.is_numeric? @style
        cite_text << page_str(cite)
      elsif cite_data.type == "citenp"
        cite_text.gsub!(item.year, "#{fc}#{item.year}#{page_str(cite)}#{lc}")
        cite_text.gsub!(", #{fc}", " #{fc}")
      else 
        cite_text << page_str(cite)
      end

      cite_text.gsub!(",", "&#44;") if @links # replace comma

      return cite_text, fc, lc
    end
  end
end


