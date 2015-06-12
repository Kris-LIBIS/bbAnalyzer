require 'nokogiri'
require 'uri'
require 'pathname'
require 'set'
require 'csv'

class BbAnalyzer
  def initialize(root_dir)
    @root_dir = Pathname.new(root_dir)
    @collections = {collections: {}, ies: []}
    @ie_list = Array.new
    @file_list = Set.new
    process_dir(Pathname.new '.')
    # puts 'Files found:'
    # @file_list.sort.each { |f| puts " - #{f}" }
    puts 'IEs:'
    print_collection @collections
    dis = discrepancies
    puts 'Discrepanties:'
    if dis[:not_found].size > 0
      puts ' + Verwijzigen in HTML, maar niet gevonden:'
      dis[:not_found].each { |f| puts "   - #{f}"}
    end
    if dis[:unreferenced].size > 0
      puts ' + Bestanden gevonden, zonder verwijzing in een HTML bestand (en dus niet opgenomen):'
      dis[:unreferenced].each { |f| puts "   - #{f}"}
    end
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
        ie[:attachments].each do |attachment|
          csv << ['', '', attachment.basename.to_s, (@root_dir + attachment).exist? ? '' : '** BESTAND ONTBREEKT !! **']
        end
      end
    end
  end

  def discr_to_csv
    disc = discrepancies
    CSV.open('missing.csv', 'wt') do |csv|
      csv << %w(Folder Bestandsnaam)
      disc[:not_found].sort.each { |f| csv << [f.dirname.to_s, f.basename.to_s] }
    end
    CSV.open('notused.csv', 'wt') do |csv|
      csv << %w(Folder Bestandsnaam)
      disc[:unreferenced].sort.each { |f| csv << [f.dirname.to_s, f.basename.to_s] }
    end
  end

  protected

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
    attachments = html.xpath('//a/@href').map(&:value).map { |link| cleanup(link, rel_path) }.compact
    images = html.xpath('//img/@src').map(&:value).map { |link| cleanup(link, rel_path) }.compact
    # Title
    titles = html.css('div table tr td div span strong').map(&:content)
    # Store result
    ie = {
        path: rel_path,
        filename: rel_name.basename,
        title: titles.first.gsub(/[\r\n]/, ''),
        attachments: attachments,
        images: images
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
      ie[:attachments].each do |file|
        files_notfound << file unless files_unreferenced.delete?(file) or (@root_dir + file).exist?
      end
      ie[:images].each do |file|
        files_notfound << file unless files_unreferenced.delete?(file) or (@root_dir + file).exist?
        # or should we: ??
        # files_ignored << file unless files_unreferenced.delete?(file) or (@root_dir + file).exist?
      end
    end
    # optional:
    # files_unreferenced.to_a.select do |f|
    #   f.fnmatch? '*/TempBody_*.gif'
    # end.each do |f|
    #   files_ignored << files_unreferenced.delete(f)
    # end
    {not_found: files_notfound, unreferenced: files_unreferenced, ignored: files_ignored}
  end

  private

  def cleanup(link, rel_name)
    path = Pathname.new(URI.unescape(link))
    return nil if path.fnmatch?('') or path.fnmatch?('http*') or path.absolute?
    (rel_name + path).cleanpath
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
    ie[:attachments].each do |attachment|
      puts "#{' ' * indent}   . #{ '** BESTAND ONTBREEKT !! ** ' unless (@root_dir + attachment).exist?}#{attachment.basename}"
    end
  end



end

BbAnalyzer.new(ARGV[0] || '.')
