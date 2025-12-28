require 'json'
require 'rtesseract'
require 'mini_magick'

# Constants
SCREEN_REGION_WIDTH_RATIO = 0.4         # 40% of screen width
SCREEN_REGION_HEIGHT_RATIO = 0.10       # 15% of screen height
SCREEN_REGION_LEFT_OFFSET_RATIO = 0.55  # 55% offset from left
SCREEN_REGION_TOP_OFFSET_RATIO = 0.3    # 20% offset from top
DEFAULT_CHECK_INTERVAL = 1.0            # seconds
DEFAULT_OCR_PSM_MODE = 6                # PSM 6 = uniform block of text
FALLBACK_SCREEN_WIDTH = 1920
FALLBACK_SCREEN_HEIGHT = 1080

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

# Get screen size on Windows using PowerShell
def get_screen_size_windows
  begin
    ps_script = "[System.Windows.Forms.Screen]::PrimaryScreen.Bounds"
    result = `powershell -Command "Add-Type -AssemblyName System.Windows.Forms; #{ps_script}" 2>nul`.strip
    if result =~ /Width[=:](\d+).*Height[=:](\d+)/ || result =~ /(\d+),\s*(\d+)/
      return [$1.to_i, $2.to_i]
    end
  rescue
  end
  
  # Fallback: try to get dimensions separately
  begin
    width = `powershell -Command "[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width" 2>nul`.strip.to_i
    height = `powershell -Command "[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height" 2>nul`.strip.to_i
    return [width, height] if width > 0 && height > 0
  rescue
  end
  
  nil
end

# Capture screen region on Windows using PowerShell
def capture_screen_windows(left, top, width, height, output_file)
  abs_output_file = File.expand_path(output_file).gsub('/', '\\')
  ps_script_file = File.expand_path("temp_capture_#{Time.now.to_f}.ps1").gsub('/', '\\')
  
  begin
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
    system("powershell.exe -ExecutionPolicy Bypass -File \"#{ps_script_file}\"")
    sleep(0.2) # Wait for file write
    
    File.exist?(abs_output_file) && File.size(abs_output_file) > 0
  rescue
    false
  ensure
    File.delete(ps_script_file) if File.exist?(ps_script_file)
  end
end

# Clean up temporary files (unless debug mode is enabled)
def cleanup_temp_files(debug = false)
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
  
  puts "Cleaned up #{cleaned_count} temporary file(s)" if cleaned_count > 0
end

# Capture screen region for monitoring (middle row, left side for "Clue:" detection)
def capture_screen_center(center_width = nil, center_height = nil, debug = false)
  temp_file = "temp_screen_center_#{Time.now.to_f}.png"
  
  begin
    # Detect OS and get screen dimensions
    screen_width, screen_height = if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
      screen_size = get_screen_size_windows
      if screen_size.nil?
        puts "  Warning: Could not detect screen size, using fallback: #{FALLBACK_SCREEN_WIDTH}x#{FALLBACK_SCREEN_HEIGHT}" if debug
        [FALLBACK_SCREEN_WIDTH, FALLBACK_SCREEN_HEIGHT]
      else
        puts "  Screen size detected (Windows): #{screen_size[0]}x#{screen_size[1]}" if debug
        screen_size
      end
    else
      screen_info = `magick identify -ping -format "%wx%h" x:screen 2>nul`.strip
      if screen_info.empty? || screen_info.include?('error')
        puts "  Warning: Could not detect screen size, using fallback: #{FALLBACK_SCREEN_WIDTH}x#{FALLBACK_SCREEN_HEIGHT}" if debug
        [FALLBACK_SCREEN_WIDTH, FALLBACK_SCREEN_HEIGHT]
      else
        size = screen_info.split('x').map(&:to_i)
        puts "  Screen size detected (ImageMagick): #{size[0]}x#{size[1]}" if debug
        size
      end
    end
    
    # Capture region: middle row, columns 1-2 (left side, starting from 0%)
    region_width = center_width || (screen_width * SCREEN_REGION_WIDTH_RATIO).to_i
    region_height = center_height || (screen_height * SCREEN_REGION_HEIGHT_RATIO).to_i
    left = (screen_width * SCREEN_REGION_LEFT_OFFSET_RATIO).to_i
    top = (screen_height * SCREEN_REGION_TOP_OFFSET_RATIO).to_i
    
    if debug
      puts "  Monitoring region: #{region_width}x#{region_height} pixels"
      puts "  Region position: (#{left}, #{top}) - (#{left + region_width}, #{top + region_height})"
      puts "  Region covers: #{(region_width.to_f / screen_width * 100).round(1)}% width, #{(region_height.to_f / screen_height * 100).round(1)}% height"
    end
    
    # Capture the region
    success = if RUBY_PLATFORM =~ /mswin|mingw|cygwin/
      puts "  Attempting PowerShell screen capture..." if debug
      result = capture_screen_windows(left, top, region_width, region_height, temp_file)
      puts result ? "  PowerShell capture succeeded" : "  PowerShell capture failed" if debug
      result
    else
      system("magick x:screen -crop #{region_width}x#{region_height}+#{left}+#{top} +repage \"#{temp_file}\"", 
             out: File::NULL, err: File::NULL)
    end
    
    # Verify capture
    abs_temp_file = File.expand_path(temp_file)
    if File.exist?(abs_temp_file) && File.size(abs_temp_file) > 0
      puts "  Captured file: #{abs_temp_file} (#{File.size(abs_temp_file)} bytes)" if debug
      {
        file: temp_file,
        offset_x: left,
        offset_y: top,
        width: region_width,
        height: region_height,
        screen_width: screen_width,
        screen_height: screen_height
      }
    else
      puts "  Error: Failed to capture screen region" if debug
      File.delete(temp_file) if File.exist?(temp_file) && !debug
      nil
    end
  rescue => e
    puts "  Error capturing screen: #{e.message}" if debug
    File.delete(temp_file) if File.exist?(temp_file) && !debug
    nil
  end
end

# Find "Clue:" text in the captured screen region using OCR
def find_clue_text_on_screen(screen_path, debug = false)
  return nil unless File.exist?(screen_path)
  
  begin
    # Use the entire captured region for OCR (already contains the relevant area)
    text = extract_text_from_image(screen_path, DEFAULT_OCR_PSM_MODE)
    
    puts "  Extracted text: '#{text}'" if debug
    return text unless text.empty?
    
    nil
  rescue => e
    puts "  Error finding clue text: #{e.message}" if debug
    nil
  end
end

# Extract text from image using OCR
def extract_text_from_image(image_path, psm_mode = DEFAULT_OCR_PSM_MODE)
  return "" if image_path.nil? || !File.exist?(image_path)
  
  begin
    tesseract = RTesseract.new(image_path, psm: psm_mode)
    text = tesseract.to_s.strip.downcase.split.join(' ')  # Normalize whitespace
    text
  rescue
    ""
  end
end

# Main monitoring loop - continuously checks screen for riddles
def monitor_screen(riddles_dict, check_interval = DEFAULT_CHECK_INTERVAL, center_width = nil, center_height = nil, debug = false)
  last_printed_answer = nil
  last_detected_riddle = nil
  
  puts "Waiting for clue..."
  puts "Press Ctrl+C to stop\n"
  
  # Display screen information in debug mode
  if debug
    screen_size = RUBY_PLATFORM =~ /mswin|mingw|cygwin/ ? get_screen_size_windows : nil
    screen_size ||= begin
      info = `magick identify -ping -format "%wx%h" x:screen 2>nul`.strip
      info.empty? ? nil : info.split('x').map(&:to_i)
    end
    
    if screen_size
      puts "\n=== Screen Information ==="
      puts "Screen size: #{screen_size[0]}x#{screen_size[1]}"
      puts "Platform: #{RUBY_PLATFORM}"
      puts "Monitoring region: middle row, left side (for 'Clue:' detection)"
      puts "==========================\n"
    else
      puts "\n=== Screen Information ==="
      puts "Warning: Could not detect screen size"
      puts "Platform: #{RUBY_PLATFORM}"
      puts "==========================\n"
    end
  end
  
  check_count = 0
  
  begin
    loop do
      check_count += 1
      puts "\n--- Check ##{check_count} ---" if debug
      
      screen_data = capture_screen_center(center_width, center_height, debug)
      next unless screen_data
      
      screen_path = screen_data[:file]
      begin
        detected_text = find_clue_text_on_screen(screen_path, debug)
        
        if detected_text && !detected_text.empty?
          detected_text_clean = detected_text.strip.downcase.split.join(' ')
          puts "  Processing detected riddle: '#{detected_text_clean}'" if debug
          
          # Only process if this is a new detection
          if detected_text_clean != last_detected_riddle
            last_detected_riddle = detected_text_clean
            
            # Try to find matching riddle
            matched_riddle, matched_answer = find_matching_riddle(riddles_dict, detected_text_clean)
            
            # Print answer if found and not already printed
            if matched_answer && matched_answer != last_printed_answer
              green = "\033[32m"
              reset = "\033[0m"
              puts "Found clue: '#{matched_riddle}'"
              puts "#{green}Answer: #{matched_answer}#{reset}\n"
              last_printed_answer = matched_answer
            end
          end
        elsif debug
          puts "  No 'Clue:' text found in captured region"
        end
      ensure
        File.delete(screen_path) if File.exist?(screen_path) && !debug
      end
      
      sleep(check_interval)
    end
  rescue Interrupt
    puts "\nMonitoring stopped."
    cleanup_temp_files(debug)
  end
end

# Find matching riddle in dictionary (exact match or substring match)
def find_matching_riddle(riddles_dict, detected_text)
  # Try exact match
  return [detected_text, riddles_dict[detected_text]] if riddles_dict.key?(detected_text)
  
  [nil, nil]
end

def main
  json_file = 'riddles.json'
  debug_mode = false
  
  puts "Loading riddles..."
  riddles_dict = load_riddles(json_file)
  puts "Loaded #{riddles_dict.length} riddles.\n"
  
  monitor_screen(riddles_dict, DEFAULT_CHECK_INTERVAL, nil, nil, debug_mode)
end

main if __FILE__ == $PROGRAM_NAME
