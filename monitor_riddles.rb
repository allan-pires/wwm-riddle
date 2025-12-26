require 'json'
require 'rtesseract'
require 'mini_magick'

# Load riddles from JSON file
def load_riddles(json_file)
  riddles_list = JSON.parse(File.read(json_file, encoding: 'utf-8'))
  
  # Create a dictionary with riddle as key and answer as value
  riddles_dict = {}
  riddles_list.each do |item|
    riddle_text = item['riddle'].to_s.downcase.strip
    answer = item['answers'].to_s
    riddles_dict[riddle_text] = answer unless riddle_text.empty?
  end
  
  riddles_dict
end

def get_screen_size_windows
  # Get screen size on Windows using PowerShell
  begin
    ps_script = "[System.Windows.Forms.Screen]::PrimaryScreen.Bounds"
    result = `powershell -Command "Add-Type -AssemblyName System.Windows.Forms; #{ps_script}" 2>nul`.strip
    if result =~ /Width[=:](\d+).*Height[=:](\d+)/
      return [$1.to_i, $2.to_i]
    elsif result =~ /(\d+),\s*(\d+)/
      return [$1.to_i, $2.to_i]
    end
  rescue
  end
  
  # Fallback: try to get from system
  begin
    width = `powershell -Command "[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width" 2>nul`.strip.to_i
    height = `powershell -Command "[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height" 2>nul`.strip.to_i
    return [width, height] if width > 0 && height > 0
  rescue
  end
  
  nil
end

def capture_screen_windows(left, top, width, height, output_file)
  # Capture screen region on Windows using PowerShell
  # Use absolute path to avoid issues
  abs_output_file = File.expand_path(output_file).gsub('/', '\\')
  
  # Create a temporary PowerShell script file to avoid command line escaping issues
  ps_script_file = File.expand_path("temp_capture_#{Time.now.to_f}.ps1").gsub('/', '\\')
  
  begin
    # Escape single quotes in path for PowerShell
    escaped_path = abs_output_file.gsub("'", "''")
    
    ps_script = <<-PS
Add-Type -AssemblyName System.Drawing
$outputPath = '#{escaped_path}'
$bitmap = New-Object System.Drawing.Bitmap(#{width}, #{height})
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$size = New-Object System.Drawing.Size(#{width}, #{height})
$graphics.CopyFromScreen(#{left}, #{top}, 0, 0, $size)
$bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
    PS
    
    File.write(ps_script_file, ps_script)
    
    # Execute PowerShell script
    ps_script_file_quoted = "\"#{ps_script_file}\""
    cmd = "powershell.exe -ExecutionPolicy Bypass -File #{ps_script_file_quoted}"
    exit_status = system(cmd)
    
    # Wait a moment for file to be written (PowerShell can be slow)
    sleep(0.2)
    
    # Check if file was created successfully
    if File.exist?(abs_output_file)
      file_size = File.size(abs_output_file)
      if file_size > 0
        return true
      else
        # File exists but is empty - PowerShell might have had an error
        return false
      end
    else
      # File doesn't exist - capture failed
      return false
    end
  rescue => e
    return false
  ensure
    # Clean up PowerShell script file
    begin
      File.delete(ps_script_file) if File.exist?(ps_script_file)
    rescue
    end
  end
end

def cleanup_temp_files(debug = false)
  # Clean up all temporary files (unless debug mode is enabled)
  return if debug
  
  temp_patterns = [
    'temp_screen_center_*.png',
    'temp_left_region_*.png',
    'temp_region_*.png',
    'temp_text_region_*.png',
    'temp_capture_*.ps1',
    'temp_diff_*.png',
    'temp_result_*.txt'
  ]
  
  cleaned_count = 0
  temp_patterns.each do |pattern|
    Dir.glob(pattern).each do |file|
      begin
        File.delete(file) if File.exist?(file)
        cleaned_count += 1
      rescue => e
        puts "  Warning: Could not delete #{file}: #{e.message}"
      end
    end
  end
  
  if cleaned_count > 0
    puts "Cleaned up #{cleaned_count} temporary file(s)"
  end
end

def capture_screen_center(center_width = nil, center_height = nil, debug = false)
  # Capture the screen (full screen or specified region)
  # For finding "Clue:" on left side, we need to capture a wider area
  temp_file = "temp_screen_center_#{Time.now.to_f}.png"
  
  begin
    # Detect OS and get screen dimensions
    if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
      # Windows: Use PowerShell
      screen_size = get_screen_size_windows
      if screen_size.nil?
        screen_width = 1920
        screen_height = 1080
        if debug
          puts "  Warning: Could not detect screen size, using fallback: #{screen_width}x#{screen_height}"
        end
      else
        screen_width, screen_height = screen_size
        if debug
          puts "  Screen size detected (Windows): #{screen_width}x#{screen_height}"
        end
      end
    else
      # Linux/Mac: Try ImageMagick's x:screen (may not work on all systems)
      screen_info = `magick identify -ping -format "%wx%h" x:screen 2>nul`.strip
      if screen_info.empty? || screen_info.include?('error')
        screen_width = 1920
        screen_height = 1080
        if debug
          puts "  Warning: Could not detect screen size, using fallback: #{screen_width}x#{screen_height}"
        end
      else
        screen_width, screen_height = screen_info.split('x').map(&:to_i)
        if debug
          puts "  Screen size detected (ImageMagick): #{screen_width}x#{screen_height}"
        end
      end
    end
    
    # For finding "Clue:" in sections F and G (middle row, columns 1-2)
    # Screen divided into 5 columns x 3 rows
    # Section F: row 2, column 1 (left: 0%, top: 33.33%)
    # Section G: row 2, column 2 (left: 20%, top: 33.33%)
    # Capture both F and G: left: 20%, top: 33.33%, width: 40%, height: 50%
    region_width = center_width || (screen_width * 0.4).to_i
    region_height = center_height || (screen_height / 2).to_i
    
    # Start from sections F and G (middle row, columns 1-2)
    left = (screen_width * 0).to_i  # Start at 0% (column 1)
    top = (screen_height / 2).to_i  # Middle row starts at 1/2 (50%)
    
    if debug
      puts "  Monitoring region: #{region_width}x#{region_height} pixels"
      puts "  Region position: (#{left}, #{top}) - (#{left + region_width}, #{top + region_height})"
      puts "  Region covers: #{(region_width.to_f / screen_width * 100).round(1)}% width, #{(region_height.to_f / screen_height * 100).round(1)}% height"
    end
    
    # Capture the center region
    success = false
    if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
      # Windows: Use PowerShell
      if debug
        puts "  Attempting PowerShell screen capture..."
      end
      success = capture_screen_windows(left, top, region_width, region_height, temp_file)
      if debug
        if success
          puts "  PowerShell capture command succeeded"
        else
          puts "  PowerShell capture command failed"
        end
      end
    else
      # Linux/Mac: Use ImageMagick
      success = system("magick x:screen -crop #{region_width}x#{region_height}+#{left}+#{top} +repage \"#{temp_file}\"", out: File::NULL, err: File::NULL)
    end
    
    # Check if file exists and has content
    abs_temp_file = File.expand_path(temp_file)
    if File.exist?(abs_temp_file)
      file_size = File.size(abs_temp_file)
      if file_size > 0
        success = true
        if debug
          puts "  Captured file exists: #{abs_temp_file} (#{file_size} bytes)"
        end
      else
        if debug
          puts "  Captured file exists but is empty (0 bytes): #{abs_temp_file}"
        end
        File.delete(abs_temp_file) unless debug
        success = false
      end
    else
      if debug
        puts "  Captured file was not created: #{abs_temp_file}"
        puts "  Current directory: #{Dir.pwd}"
      end
      success = false
    end
    
    if success
      # Return both the file path and the offset coordinates
      return { 
        file: temp_file, 
        offset_x: left, 
        offset_y: top, 
        width: region_width, 
        height: region_height,
        screen_width: screen_width,
        screen_height: screen_height
      }
    else
      if debug
        puts "  Error: Failed to capture screen region"
      end
      File.delete(temp_file) if !debug && File.exist?(temp_file)
      return nil
    end
  rescue => e
    if debug
      puts "  Error capturing screen: #{e.message}"
    end
    File.delete(temp_file) if !debug && File.exist?(temp_file)
    return nil
  end
end

def find_template_match(screen_path, template_path, similarity_threshold = 0.80, debug = false)
  # Use ImageMagick's compare to find template matches
  # Returns array of [x, y] coordinates where template was found
  return [] unless File.exist?(screen_path) && File.exist?(template_path)
  
  begin
    # Get template dimensions
    template_info = `magick identify -ping -format "%wx%h" "#{template_path}" 2>nul`.strip
    if template_info.empty?
      puts "  Error: Could not read template image dimensions" if debug
      return []
    end
    
    template_width, template_height = template_info.split('x').map(&:to_i)
    
    # Get screen/captured region dimensions
    screen_info = `magick identify -ping -format "%wx%h" "#{screen_path}" 2>nul`.strip
    if screen_info.empty?
      puts "  Error: Could not read captured screen region dimensions" if debug
      return []
    end
    screen_width, screen_height = screen_info.split('x').map(&:to_i)
    
    if debug
      puts "  Template size: #{template_width}x#{template_height} pixels"
      puts "  Search area (captured region): #{screen_width}x#{screen_height} pixels"
      puts "  Search space: #{(screen_width - template_width + 1) * (screen_height - template_height + 1)} possible positions"
    end
    
    matches = []
    
    # Use a smaller step size to avoid missing matches
    # Step size should be about 1/4 of template size, but at least 10 pixels
    step_size = [[template_width / 4, template_height / 4].min, 10].max
    
    if debug
      puts "  Using step size: #{step_size}, similarity threshold: #{similarity_threshold}"
    end
    
    best_similarity = 0.0
    checked_positions = 0
    
    # Search in a grid pattern with smaller steps
    (0..(screen_height - template_height)).step(step_size) do |y|
      (0..(screen_width - template_width)).step(step_size) do |x|
        checked_positions += 1
        
        # Extract region
        region_file = "temp_region_#{x}_#{y}_#{Time.now.to_f}.png"
        success = system("magick \"#{screen_path}\" -crop #{template_width}x#{template_height}+#{x}+#{y} +repage \"#{region_file}\"", out: File::NULL, err: File::NULL)
        
        if success && File.exist?(region_file) && File.size(region_file) > 0
          # Compare with template using RMSE metric
          compare_result = `magick compare -metric RMSE "#{region_file}" "#{template_path}" null: 2>&1`.strip
          
          # RMSE returns a value like "1234.5 (0.019)" where the number in parentheses is normalized (0-1)
          # Lower normalized value = better match
          if compare_result =~ /\(([\d.]+)\)/
            normalized_diff = $1.to_f
            similarity = 1.0 - normalized_diff
            best_similarity = similarity if similarity > best_similarity
            
            if similarity >= similarity_threshold
              matches << [x, y, similarity]
              if debug
                puts "  Found match at (#{x}, #{y}) with similarity: #{similarity.round(4)}"
              end
            end
          end
          
          File.delete(region_file) if File.exist?(region_file)
        end
      end
    end
    
    if debug
      puts "  Checked #{checked_positions} positions, best similarity: #{best_similarity.round(4)}"
      puts "  Found #{matches.length} match(es) above threshold"
    end
    
    # Sort by similarity (highest first) and return coordinates
    matches.sort_by { |m| -m[2] }.map { |m| [m[0], m[1]] }
  rescue => e
    puts "  Template matching error: #{e.message}" if debug
    []
  end
end

def find_clue_text_on_screen(screen_path, debug = false)
  # Look for "Clue:" text on the left side of the screen, in the middle
  return nil unless File.exist?(screen_path)
  
  begin
    # Get screen dimensions
    screen_info = `magick identify -ping -format "%wx%h" "#{screen_path}" 2>nul`.strip
    return nil if screen_info.empty?
    screen_width, screen_height = screen_info.split('x').map(&:to_i)
    
    # The captured region already contains sections F and G
    # Search within the entire captured region for "Clue:" text
    # Use the full captured region for OCR
    left_region_width = screen_width  # Use full width of captured region
    left_region_height = screen_height  # Use full height of captured region
    left_region_left = 0  # Start from left of captured region
    left_region_top = 0  # Start from top of captured region
    
    if debug
      puts "  Searching for 'Clue:' in captured region (sections F and G): (#{left_region_left}, #{left_region_top}) size: #{left_region_width}x#{left_region_height}"
    end
    
    # Extract the left region
    left_region_file = "temp_left_region_#{Time.now.to_f}.png"
    success = system("magick \"#{screen_path}\" -crop #{left_region_width}x#{left_region_height}+#{left_region_left}+#{left_region_top} +repage \"#{left_region_file}\"", out: File::NULL, err: File::NULL)
    
    if success && File.exist?(left_region_file) && File.size(left_region_file) > 0
      # Extract text from this region
      text = extract_text_from_image(left_region_file, 6)  # PSM 6 for uniform block
      
      if debug
        puts "  Extracted text from left region: '#{text}'"
      end
      
      # Look for "Clue:" in the text
      if text.downcase.include?("clue:")
        # Found "Clue:", now extract the riddle text
        # The riddle should be after "Clue:"
        clue_index = text.downcase.index("clue:")
        riddle_text = text[clue_index + 5..-1].strip  # Get text after "Clue:"
        
        # Handle multi-line text - take everything up to the first newline or end of string
        # Replace newlines and multiple spaces with single spaces
        riddle_text = riddle_text.split(/\n|\r/).first.strip  # Get first line only
        riddle_text = riddle_text.split.join(' ')  # Normalize whitespace
        
        if debug
          puts "  Found 'Clue:' at position #{clue_index}"
          puts "  Riddle text after 'Clue:': '#{riddle_text}'"
        end
        
        File.delete(left_region_file) if !debug && File.exist?(left_region_file)
        return riddle_text unless riddle_text.empty?
      end
      
      File.delete(left_region_file) if !debug && File.exist?(left_region_file)
      return nil
    else
      File.delete(left_region_file) if !debug && File.exist?(left_region_file)
      return nil
    end
  rescue => e
    if debug
      puts "  Error finding clue text: #{e.message}"
    end
    ""
  end
end

def extract_text_from_image(image_path, psm_mode = 6)
  return "" if image_path.nil? || !File.exist?(image_path)
  
  begin
    # Use rtesseract to extract text
    # psm 6 = Assume a single uniform block of text (good for multi-word)
    # psm 8 = Single word
    tesseract = RTesseract.new(image_path, psm: psm_mode)
    text = tesseract.to_s.strip.downcase
    # Clean up the text: remove extra whitespace
    text = text.split.join(' ')
    text
  rescue => e
    # Silently handle OCR errors
    ""
  end
end

def monitor_screen(riddles_dict, check_interval = 1.0, center_width = nil, center_height = nil, debug = true)
  last_printed_answer = nil  # Track last printed answer to avoid duplicates
  last_detected_riddle = nil  # Track last detected riddle text
  
  if center_width && center_height
    puts "Region size: #{center_width}x#{center_height} pixels (custom)"
  else
    puts "Region size: ~40% width x ~33% height (sections F and G: middle row, columns 2-3, auto-calculated)"
  end
  puts "Waiting for clue..."
  puts "Press Ctrl+C to stop\n"
  
  # Get initial screen info for display
  if debug
    if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
      # Windows: Use PowerShell
      screen_size = get_screen_size_windows
      if screen_size
        initial_width, initial_height = screen_size
        puts "\n=== Screen Information ==="
        puts "Primary screen size: #{initial_width}x#{initial_height}"
        puts "Platform: Windows"
        puts "Note: The script captures sections F and G (middle row, columns 2-3) for 'Clue:' detection"
        puts "==========================\n"
      else
        puts "\n=== Screen Information ==="
        puts "Warning: Could not detect screen size"
        puts "Platform: Windows"
        puts "==========================\n"
      end
    else
      # Linux/Mac: Try ImageMagick
      initial_screen_info = `magick identify -ping -format "%wx%h" x:screen 2>nul`.strip
      if !initial_screen_info.empty?
        initial_width, initial_height = initial_screen_info.split('x').map(&:to_i)
        puts "\n=== Screen Information ==="
        puts "Full screen/virtual desktop size: #{initial_width}x#{initial_height}"
        puts "Platform: #{RUBY_PLATFORM}"
        puts "Note: On multi-monitor setups, this shows the combined virtual desktop size"
        puts "The script monitors the center region of this virtual desktop"
        puts "==========================\n"
      else
        puts "\n=== Screen Information ==="
        puts "Warning: Could not detect screen size"
        puts "Platform: #{RUBY_PLATFORM}"
        puts "==========================\n"
      end
    end
  end
  
  check_count = 0
  
  begin
    loop do
      check_count += 1
      if debug
        puts "\n--- Check ##{check_count} ---"
      end
      
      # Capture center portion of screen
      screen_data = capture_screen_center(center_width, center_height, debug)
      
      unless screen_data.nil?
        screen_path = screen_data[:file]
        begin
          # Look for "Clue:" text on the left side of the screen
          detected_text = find_clue_text_on_screen(screen_path, debug)
          
          if !detected_text.nil? && !detected_text.empty?
            # Clean and normalize the text - preserve multi-word clues
            detected_text_clean = detected_text.strip.downcase
            # Normalize whitespace but keep the full phrase
            detected_text_clean = detected_text_clean.split.join(' ')
            
            if debug
              puts "  Processing detected riddle text: '#{detected_text_clean}'"
            end
            
            # Only process if this is a new detection (avoid re-processing same text)
            if detected_text_clean != last_detected_riddle
              last_detected_riddle = detected_text_clean
              
              # Check if the detected text matches any riddle exactly
              matched_riddle = nil
              matched_answer = nil
              
              if riddles_dict.key?(detected_text_clean)
                matched_riddle = detected_text_clean
                matched_answer = riddles_dict[detected_text_clean]
              else
                # Try fuzzy matching - check if any riddle contains the detected text or vice versa
                riddles_dict.each do |riddle, answer|
                  # Try exact match first (case-insensitive)
                  if detected_text_clean == riddle
                    matched_riddle = riddle
                    matched_answer = answer
                    break
                  # Try substring matching
                  elsif detected_text_clean.include?(riddle) || riddle.include?(detected_text_clean)
                    matched_riddle = riddle
                    matched_answer = answer
                    break
                  end
                end
              end
              
              # Only print if we found a match and haven't printed this answer recently
              if matched_answer && matched_answer != last_printed_answer
                # ANSI color codes: green = \033[32m, reset = \033[0m
                green = "\033[32m"
                reset = "\033[0m"
                puts "Found clue: '#{matched_riddle}'"
                puts "#{green}Answer: #{matched_answer}#{reset}\n"
                last_printed_answer = matched_answer
              end
            end
          elsif debug
            puts "  No 'Clue:' text found in captured region (sections F and G)"
          end
        ensure
          # Clean up temp file after processing (unless debug mode is enabled)
          File.delete(screen_path) if !debug && File.exist?(screen_path)
        end
      end
      
      sleep(check_interval)
    end
  rescue Interrupt
    puts "\nMonitoring stopped."
    cleanup_temp_files(debug)
  end
end

def main
  json_file = 'riddles.json'
  
  # Set to true to see debugging output
  debug_mode = false
  
  puts "Loading riddles..."
  riddles_dict = load_riddles(json_file)
  puts "Loaded #{riddles_dict.length} riddles.\n"
  
  # Start monitoring
  # You can enable debug mode by changing debug_mode to true above
  monitor_screen(riddles_dict, 1.0, nil, nil, debug_mode)
end

main if __FILE__ == $PROGRAM_NAME
