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
    @html_not_found = Array.new
    @html_duplicate = Array.new
    @bad_filenames = Array.new
    get_files Pathname.new('.')
    @file_list_dup = @file_list.dup
    process_csv(csv)
    puts 'IEs:'
    print_collection @collections
    dis = discrepancies
    puts 'Discrepanties:'
    if dis[:not_found].size > 0
      puts ' + Verwijzigen in HTML, maar niet gevonden:'
      dis[:not_found].each { |f| puts "   - #{f[:dir].to_s} / #{f[:html].to_s} : #{f[:link]}" }
    end
    if dis[:unreferenced].size > 0
      puts ' + Bestanden gevonden, zonder verwijzing in een HTML bestand (en dus niet opgenomen):'
      dis[:unreferenced].each { |f| puts "   - #{f}" }
    end
    if dis[:double_referenced].size > 0
      puts ' + Bestanden met referenties uit meer dan 1 HTML bestand (en dus meerdere keren opgeladen):'
      dis[:double_referenced].each do |k, v|
        puts "   - #{k.to_s}"
        v.each { |f| puts "     - #{f[:dir].to_s}/#{f[:html].to_s}" }
      end
    end
    ie_to_csv
    discr_to_csv
  end

  def ie_to_csv
    CSV.open('ie_list.csv', 'wt') do |csv|
      csv << ['Collectie', 'IE naam (dc:title)', 'Bestand', 'Opmerking']
      @ie_list.sort_by {|f| (f[:path] + f[:filename]).to_s}.each do |ie|
        csv << [ie[:path].to_s, ie[:title], ie[:filename].to_s]
        ie[:links].sort.each do |link|
          csv << ['', '', link, (@root_dir + ie[:path] + link).exist? ? '' : '** BESTAND ONTBREEKT !! **']
        end
        ie[:images].sort.each do |link|
          csv << ['', '', link, (@root_dir + ie[:path] + link).exist? ? '' : '** BESTAND ONTBREEKT !! **']
        end
      end
    end
  end

  def discr_to_csv
    disc = discrepancies
    CSV.open('notfound.csv', 'wt') do |csv|
      csv << %w(Folder Html Link)
      disc[:not_found].each { |f| csv << [f[:dir].to_s, f[:html].to_s, f[:link].to_s] }
    end
    CSV.open('notreferenced.csv', 'wt') do |csv|
      csv << %w(Folder Bestandsnaam)
      disc[:unreferenced].each { |f| csv << [f.dirname.to_s, f.basename.to_s] }
    end
    CSV.open('doublereferenced.csv', 'wt') do |csv|
      csv << %w(Folder Bestandsnaam HTML_bestand)
      disc[:double_referenced].each do |_, v|
        v.each { |f| csv << [f[:dir].to_s, f[:link].to_s, f[:html].to_s] }
      end
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
    CSV.open('bad_files.csv', 'wt') do |csv|
      csv << %w(BadName RenameTo)
      @bad_filenames.each do |f|
        csv << ["#{File.join(f[:path], f[:parts].join('?'))}", f[:new_name] || '???']
      end
    end
  end

  protected

  def get_files(rel_path)
    abs_path = @root_dir + rel_path
    abs_path.entries.each do |name|
      begin
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
      rescue
        nameparts = name.to_s.encode(replace: '|', undef: :replace, invalid: :replace).split('|')
        @bad_filenames << {path: rel_path.to_s, bad_name: name.to_s, parts: nameparts}
      end
    end
  end

  def process_csv(path = nil)
    if path
      CSV.open(path, 'rb:windows-1252:UTF-8', headers: true) do |csv|
        # CSV.open(path, 'rb', headers: true) do |csv|
        csv.each do |row|
          fname = Pathname.new(row[5].gsub(/^c:\\export\\/, '').gsub(/\\/, '/'))
          if @file_list.delete?(fname)
            process_ie fname
          elsif @file_list_dup.include?(fname)
            @html_duplicate << fname
            # elsif find_bad(fname.parent.to_s, fname.basename.to_s)
            #   process_ie fname
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
      to_delete.each { |fpath| @file_list.delete fpath }
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

  def ignore_file(rel_name)
    rel_name.to_s =~ /icons\/.*\.gif/ || rel_name.to_s =~ /\/(TempBody.*|graycol)\.(gif|jpg)$/
  end

  def ignore_link(link)
    return true if link =~ /^(mailto:|http:)/
    ignore_file(link)
  end

  # @param [Pathname] rel_name
  def process_file(rel_name)
    return if ignore_file(rel_name)
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
    links = html.xpath('//a/@href').map(&:value).map { |link| link2path(link) }.reject { |link| ignore_link(link) }
    images = html.xpath('//img/@src').map(&:value).map { |link| link2path(link) }.reject { |i| ignore_file(i) }
    # Title
    titles = html.css('div table tr td div span strong').map(&:content)
    # Store result
    ie = {
        path: rel_path,
        filename: rel_name.basename,
        title: titles.first.gsub(/[\r\n]/, ''),
        links: links,
        images: images,
    }
    @ie_list << ie
    bucket = rel_path.each_filename.to_a.inject(@collections) do |bucket, dir|
      bucket[:collections][dir.to_s] ||= {collections: {}, ies: []}
    end
    bucket[:ies] << ie
  end

  def discrepancies
    files_unreferenced = @file_list.dup
    files_referenced = Hash.new
    files_notfound = Set.new
    @ie_list.each do |ie|
      (ie[:links] + ie[:images]).each do |file|
        path = ie[:path] + file
        files_notfound << {link: file, dir: ie[:path], html: ie[:filename]} unless @file_list.include?(path)
        files_unreferenced.delete(path)
        files_referenced[path.to_s] ||= []
        unless files_referenced[path.to_s].any? { |x| x[:html] == ie[:filename] }
          files_referenced[path.to_s] << {link: file, dir: ie[:path], html: ie[:filename]}
        end
      end
    end
    {
        not_found: files_notfound.sort_by {|f| (f[:dir] + f[:link]).to_s},
        unreferenced: files_unreferenced.sort_by {|f| f.to_s },
        double_referenced: files_referenced.select { |_, v| v.size > 1 }.sort,
    }
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
    collection[:collections].sort.each do |name, content|
      puts "#{' ' * indent} + #{name}/"
      print_collection(content, indent + 2)
    end
    collection[:ies].sort_by {|f| (f[:path] + f[:filename]).to_s}.each do |ie|
      print_ie ie, indent
    end
  end

  def print_ie(ie, indent = 0)
    puts "#{' ' * indent} - #{ie[:title]} [#{ie[:filename].to_s}]"
    ie[:links].each do |link|
      puts "#{' ' * indent}   . #{ '** BESTAND ONTBREEKT !! ** ' unless (@root_dir + ie[:path] + link).exist?}#{link}"
    end
  end

  def find_bad(path, file)
    path = File.join(path, File.dirname(file)) unless File.dirname(file) == '.'
    file = File.basename(file)
    found = nil
    @bad_filenames.each do |entry|
      next unless path == entry[:path]
      regex = /^#{entry[:parts].map { |e| Regexp.quote(e) }.join('.')}$/
      regex = /^#{Regexp.quote(entry[:new_name])}$/ if entry[:new_name]
      if file =~ regex
        if found
          puts "ERROR: found multiple bad_name matches for #{File.join(path, file)}:"
          puts " - #{found}"
          puts " - #{entry}"
          return nil
        end
        puts "rename: #{File.join(path, entry[:bad_name])} to #{File.join(path, file)}" unless entry[:new_name]
        # File.rename(File.join(@root_dir, path, entry[:bad_name]), File.join(@root_dir, path, file))
        entry[:new_name] = file
        found = entry
      end
    end
    found
  end

end

BbAnalyzer.new(ARGV[0] || '.', ARGV[1])
