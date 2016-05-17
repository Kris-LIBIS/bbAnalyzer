require 'nokogiri'
require 'uri'
require 'pathname'
require 'set'
require 'csv'

class BbAnalyzer
  def initialize(root_dir, csv = nil)
    @root_dir = Pathname.new(root_dir)
    @collections = {collections: {}, ies: []}
    @ie_list = Array.new
    @file_list = Set.new
    @html_not_found = Set.new
    @html_duplicate = Set.new
    get_files Pathname.new('.')
    @file_list_dup = @file_list.dup
    process_csv(csv)
    # puts 'Files found:'
    # @file_list.sort.each { |f| puts " - #{f}" }
#    puts 'IEs:'
#    print_collection @collections
#    dis = discrepancies
#    puts 'Discrepanties:'
#    if dis[:not_found].size > 0
#      puts ' + Verwijzigen in HTML, maar niet gevonden:'
#      dis[:not_found].each { |f| puts "   - #{f}"}
#    end
#    if dis[:unreferenced].size > 0
#      puts ' + Bestanden gevonden, zonder verwijzing in een HTML bestand (en dus niet opgenomen):'
#      dis[:unreferenced].each { |f| puts "   - #{f}"}
#    end
    # puts ' + ignored:'
    # dis[:ignored].each { |f| puts "   - #{f}"}
    ie_to_csv
    discr_to_csv
  end

  def ie_to_csv
    CSV.open('ie_list.csv', 'wt') do |csv|
      csv << ['Collectie', 'IE naam (dc:title)', 'Bestand', 'Opmerking']
      @ie_list.each do |ie|
        csv << [ie[:path].to_s, ie[:title], ie[:filename].to_s]
        ie[:links].each do |link|
          csv << ['', '', link, (@root_dir + ie[:path] + link).exist? ? '' : '** BESTAND ONTBREEKT !! **']
        end
        ie[:images].each do |link|
          csv << ['', '', link, (@root_dir + ie[:path] + link).exist? ? '' : '** BESTAND ONTBREEKT !! **']
        end
      end
    end
  end

  def discr_to_csv
    disc = discrepancies
    CSV.open('notfound.csv', 'wt') do |csv|
      csv << %w(Folder Html Link)
      disc[:not_found].each { |f| csv << [f[:dir].to_s, f[:html].to_s , f[:link].to_s] }
    end
    CSV.open('ignored.csv', 'wt') do |csv|
      csv << %w(Folder Html Link)
      disc[:ignored].each { |f| csv << [f[:dir].to_s, f[:html].to_s , f[:link].to_s] }
    end
    CSV.open('notreferenced.csv', 'wt') do |csv|
      csv << %w(Folder Bestandsnaam)
      disc[:unreferenced].each { |f| csv << [f.dirname.to_s, f.basename.to_s] }
    end
    CSV.open('html_notfound.csv', 'wt') do |csv|
      csv << %w(Folder Html)
      @html_not_found.each do |f|
        csv << [f.dirname.to_s, f.basename]
      end
    end
    CSV.open('html_duplicate.csv', 'wt') do |csv|
      csv << %w(Folder Html)
      @html_duplicate.each do |f|
        csv << [f.dirname.to_s, f.basename]
      end
    end
  end

  protected

  def get_files(rel_path)
    abs_path = @root_dir + rel_path
    abs_path.entries.each do |name|
      rel_name = rel_path + name
      abs_name = abs_path + name
      case
        when abs_name.directory?
          next if rel_name == rel_path
          next if rel_name == rel_path.parent
          get_files rel_name
        when abs_name.file?
          process_file rel_name
        else
          #ignore
      end
    end
  end

  def process_csv(path = nil)
    if path 
      CSV.open(path, headers: true) do |csv|
        csv.each do |row|
          fname = Pathname.new(row[5].gsub(/^c:\\export\\/, '').gsub(/\\/, '/'))
          if @file_list.delete?(fname)
            process_ie fname
          elsif @file_list_dup.include?(fname)
            @html_duplicate << fname
          else
            @html_not_found << fname
          end
        end
      end
    else
      to_delete = []
      @file_list.each do |fpath|
        if fpath.extname == '.htm'
          process_ie(fpath)
          to_delete << fpath
        end
      end
      to_delete.each {|fpath| @file_list.delete fpath}
    end
  end

  ## Process a sub dir
  # @param [Pathname] rel_path relative path
  def process_dir(rel_path)
    abs_path = @root_dir + rel_path
    abs_path.entries.each do |name|
      rel_name = rel_path + name
      abs_name = abs_path + name
      case
        when abs_name.directory?
          next if rel_name == rel_path
          next if rel_name == rel_path.parent
          process_dir rel_name
        when abs_name.file?
          if name.extname == '.htm'
            process_ie rel_name
          else
            process_file rel_name
          end
        else
          #ignore
      end
    end
  end

  # @param [Pathname] rel_name
  def process_file(rel_name)
    return if rel_name.to_s == 'icons/graycol.gif'
    #return if rel_name.to_s =~ /\/(TempBody.*|graycol)\.gif$/
    @file_list << rel_name.cleanpath
  end

  # @param [Pathname] rel_name
  def process_ie(rel_name)
    rel_path = rel_name.parent
    f = @root_dir.join(rel_name).open
    # noinspection RubyResolve
    html = Nokogiri::HTML(f) { |config| config.strict.nonet.noblanks }
    f.close
    # Attachments
    links = html.xpath('//a/@href').map(&:value).map {|link| link2path(link)}
    links_ignored = links.select { |link| link =~ /^(mailto:|http:)/ }
    links_ok = links - links_ignored
    #links_ok = links_ok.map { |link| cleanup(link, rel_path) }
    images = html.xpath('//img/@src').map(&:value).map {|link| link2path(link)}
    images_ok = images.reject {|i| i.to_s == 'icons/graycol.gif'}
    #images_ok = images.reject {|i| i =~ /\/(TempBody.*|graycol)\.gif$/}
    images_ignored = images - images_ok
    #images_ok = images_ok.map { |link| cleanup(link, rel_path) }
    #images_ignored = images_ignored.map { |link| cleanup(link, rel_path) }
    # Title
    titles = html.css('div table tr td div span strong').map(&:content)
    # Store result
    ie = {
        path: rel_path,
        filename: rel_name.basename,
        title: titles.first.gsub(/[\r\n]/, ''),
        links: links_ok,
        ignored_links: links_ignored,
        images: images_ok,
        ignored_images: images_ignored
    }
    @ie_list << ie
    bucket = rel_path.each_filename.to_a.inject(@collections) do |bucket, dir|
      bucket[:collections][dir.to_s] ||= {collections: {}, ies: []}
    end
    bucket[:ies] << ie
  end

  def discrepancies
    files_unreferenced = @file_list.dup
    files_notfound = Set.new
    files_ignored = Set.new
    @ie_list.each do |ie|
      ie[:links].each do |file|
        files_notfound << { link: file, dir: ie[:path], html: ie[:filename] } unless files_unreferenced.delete?(ie[:path] + file)
      end
      ie[:images].each do |file|
        files_notfound << { link: file, dir: ie[:path], html: ie[:filename] } unless files_unreferenced.delete?(ie[:path] + file)
      end
      ie[:ignored_links].each do |file|
        files_unreferenced.delete(file)
        files_ignored << { dir: ie[:path], html: ie[:filename], link: file }
      end
    end
    {not_found: files_notfound, unreferenced: files_unreferenced, ignored: files_ignored}
  end

  private

  def cleanup(link, rel_name)
    path = Pathname.new(URI.unescape(link))
    (rel_name + path).cleanpath
  end

  def link2path(link)
    Pathname.new(URI.unescape(link)).cleanpath.to_s
  end

  def print_collection(collection, indent = 0)
    collection[:collections].each do |name, content|
      puts "#{' ' * indent} + #{name}/"
      print_collection(content, indent + 2)
    end
    collection[:ies].each do |ie|
      print_ie ie, indent
    end
  end

  def print_ie(ie, indent = 0)
    puts "#{' ' * indent} - #{ie[:title]}"
    ie[:links].each do |link|
      puts "#{' ' * indent}   . #{ '** BESTAND ONTBREEKT !! ** ' unless (@root_dir + ie[:path] + link).exist?}#{link}"
    end
  end



end

BbAnalyzer.new(ARGV[0] || '.', ARGV[1])
