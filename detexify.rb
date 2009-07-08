require 'couchrest'
require 'extended_enumerable'
require 'matrix'
require 'math'
require 'preprocessors'
require 'extractors'
require 'image_moments'
require 'RMagick'

module Detexify
    
  class Sample < CouchRest::ExtendedDocument
    dburl = ENV['COUCH'] || "http://127.0.0.1:5984/samples"
    use_database CouchRest.database!(dburl)
    property :command
    property :feature_vector
    property :strokes
    
    timestamps!
                          
    def source
      fetch_attachment 'source'
    end
    
  end

  class Classifier
    
    module Features
      
      module Hu
        extend ImageMoments
        
        module_function
        
        def extract data
          h = img2hu(data2img(data))
        end
        
        def data2img data
          img = Magick::Image::from_blob(data).first
          puts img.inspect
          puts "-"*80
          puts "got image"
          puts "  Format: #{img.format}"
          puts "  Geometry: #{img.columns}x#{img.rows}"
          puts "  Depth: #{img.depth} bits-per-pixel"
          puts "  Colors: #{img.number_colors}"
          puts "  Filesize: #{img.filesize}"
          puts "-"*80
          img
        end

        def img2hu img
          puts "-"*80
          puts "computing hu moments"
          # FIXME next statement uses opacity which is VERY STRANGE but it only works that way
          a = (0..(img.rows-1)).collect { |n| img.get_pixels(0,n,img.columns,1).collect { |p| p.opacity } }
          m = Matrix[*a]
          puts "panic!!!!!! zero matrix" if m == Matrix.zero(m.column_size)
          h = hu_vector(m, 0..(m.column_size-1), 0..(m.row_size-1) )
          puts "hu moments"
          puts "  #{h.inspect}"
          puts "-"*80
          h
        end
        
      end
      
      # extract online fetures
      module Online
        
        module_function
        
        def extract s
          strokes = s.map { |stroke| stroke.map { |point| point.dup } } # s.dup enough?
          # preprocess strokes
          
          # TODO chop off heads and tails
          # strokes = strokes.map do |stroke|
          #   Preprocessors::Chop.new(:points => 5, :degree => 180).process(stroke)            
          # end

          # TODO smooth out points (avarage over three points)
          # strokes = strokes.map do |stroke|
          #   Preprocessors::Smooth.new.process(stroke)            
          # end
                    
          left, right, top, bottom = Detexify::Online::Extractors::BoundingBox.new.call(strokes)
          
          # TODO push this into a preprocessor
          # computations for next step
          height = top - bottom
          width = right - left
          ratio = width/height
          long, short = ratio > 1 ? [width, height] : [height, width]
          offset =  if ratio > 1
                      { 'x' => 0.0 , 'y' => (1.0 - short/long)/2.0 }
                    else
                      { 'x' => (1.0 - short/long)/2.0 , 'y' => 0.0 }
                    end
          
          # move left and bottom to zero, scale to fit and then center
          strokes.each do |stroke|
            stroke.each do |point|
              point['x'] = ((point['x'] - left) / long) + offset['x']
              point['y'] = ((point['y'] - bottom) / long) + offset['y']
            end
          end          
          
          # convert to equidistant point distributon
          strokes = strokes.map do |stroke|
            Detexify::Online::Preprocessors::EquidistantPoints.new(:distance => 0.01).process(stroke)            
          end
                    
          # FIXME I've lost the timestamps here. Dunno if I want to keep them
          
          extractors = []
          # extract features
          # - directional histogram features
          extractors << Detexify::Online::Extractors::DirectionalHistogramFeatures.new
          # - start direction
          # - end direction
          # startdirection, enddirection = Extractors::StartEndDirection.new.process(strokes)
          # - start/end position
          # - point density
          boxes = [
            {'x' => (0...0.4), 'y' => (0..1)},
            {'x' => (0.4...0.6), 'y' => (0..1)},
            {'x' => (0.6..1), 'y' => (0..1)},
            {'y' => (0...0.4), 'x' => (0..1)},
            {'y' => (0.4...0.6), 'x' => (0..1)},
            {'y' => (0.6..1), 'x' => (0..1)},
          ]
          extractors << Detexify::Online::Extractors::PointDensity.new(*boxes)
          # - aspect ratio
          # - number of strokes
          extractors << Proc.new { |s| (s.size*10).to_f }
          # TODO add more features
          return Vector.elements(extractors.map { |e| e.call(strokes) }.flatten)
        end
        
      end
      
    end
    
    ### class Classifier
    
    K = 5
  
    def initialize
      @samples = Sample
      # all = reload # doing this lazily
    end
    
    # This is expensive
    # TODO load only { Vector => command } Hash (via CoucDB map)
    def samples
      @all ||= @samples.all.select { |s| symbols.member? s.command }
    end
    
    def symbols
      cmds, more = open('commands.txt') do |f|
        f.readlines
      end.reject do |c|
        c =~ /\A#/
      end.map do
        |c| c.strip
      end.partition do |c|
        c !~ /\{\}/
      end
      more.each do |command|
        (('a'..'z').to_a+('A'..'Z').to_a).each do |char|
          cmds << command.sub(/\{\}/,"{#{char}}") 
        end
      end
      cmds
    end
    
    def count_hash
      h = {}
      symbols.each do |sym|
        h[sym] = 0
      end
      samples.each do |s|
        h[s.command] += 1
      end
      h
    end
    
    def gimme_tex
      # TODO refoactor so that it is prettier
      cmds = symbols
      cmdh = {}
      cmds.each do |cmd|
        cmdh[cmd] = 0
      end
      samples.each do |sample|
        if cmdh[sample.command]
          cmdh[sample.command] += 1
        else
          puts "****** Hilfe! Fremdes Symbol: #{sample.command}"
        end
      end
      cmdh.sort_by { |c,n| n }.first.first
    end
    
    def count_samples tex
      #samples.count { |s| s.command == tex }
      samples.select { |s| s.command == tex }.size
    end
  
    # train the classifier by adding io to symbol class tex
    def train tex, io, strokes
      # TODO reject illegal input e.g. empty strokes
      # TODO offload feature extraction to a job queue
      f = extract_features io.read, strokes
      io.rewind
      sample = @samples.new(:command => tex, :feature_vector => f.to_a, :strokes => strokes)
      sample.save
      sample.put_attachment('source', io.read, :content_type => io.content_type)
      samples << sample
    end
  
    # returns [{ :command => "foo", :score => "100", }]
    def classify io, strokes # TODO modules KNN, Mean, etc. for different classifier types? 
      f = extract_features io.read, strokes
      # use nearest neighbour classification
      # sort by distance and find minimal distance for each command
      nearest = {}
      all = samples.sort_by do |sample|
        d = distance(f, Vector.elements(sample.feature_vector))
        nearest[sample.command] = d if !nearest[sample.command] || nearest[sample.command] > d
        d
      end
      neighbours = {} # holds nearest distance of each command to the pattern
      # K is number of best matches we want in the list
      while !all.empty? && neighbours.size < K
        sample = all.shift
        neighbours[sample.command] ||= 0
        neighbours[sample.command] += 1
      end
      # we are adding everything that is not in the nearest list with LARGE distance
      missing = symbols - nearest.keys
      return [neighbours.map { |command, num| { :tex => command, :score => num } }.sort_by { |h| -h[:score] },
              nearest.map { |command, dist| { :tex => command, :score => dist } }.sort_by{ |h| h[:score] } + missing.map { |command| { :tex => command, :score => 999999} } ]
    end
    
    def distance x, y
      # TODO find a better distance function
      MyMath.euclidean_distance(x, y)
    end
    
    def regenerate_features
      puts "regenerating features"
      # FIXME see extended_enumerable.rb
      #@samples.each do |s|
      @samples.all.each do |s|
        f = extract_features(s.source, s.strokes)
        puts f.inspect
        s.feature_vector = f.to_a
        s.save
      end
      puts "done."
    end

    protected

    def extract_features data, strokes # data is String
      Features::Online.extract strokes # maybe use something different in the future
    end
        
  end
    
end