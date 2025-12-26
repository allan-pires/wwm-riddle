require 'json'
require 'rtesseract'

# Load the same functions from monitor_riddles.rb
# We'll define them here for the test to work standalone
def load_riddles(json_file)
  riddles_list = JSON.parse(File.read(json_file, encoding: 'utf-8'))
  
  riddles_dict = {}
  riddles_list.each do |item|
    riddle_text = item['riddle'].to_s.downcase.strip
    answer = item['answers'].to_s
    riddles_dict[riddle_text] = answer unless riddle_text.empty?
  end
  
  riddles_dict
end

def extract_text_from_image(image_path, psm_mode = 6)
  return "" if image_path.nil? || !File.exist?(image_path)
  
  begin
    tesseract = RTesseract.new(image_path, psm: psm_mode)
    text = tesseract.to_s.strip.downcase
    text = text.split.join(' ')
    text
  rescue => e
    puts "OCR error: #{e.message}" if $DEBUG
    ""
  end
end

# Test script to find riddle answers from riddle-match.jpg
def test_riddle_match
  json_file = 'riddles.json'
  test_image = 'riddle-match-2.jpg'
  
  puts "=" * 60
  puts "Testing Riddle Match Detection"
  puts "=" * 60
  puts
  
  # Check if files exist
  unless File.exist?(test_image)
    puts "Error: Test image '#{test_image}' not found!"
    return
  end
  
  unless File.exist?(json_file)
    puts "Error: Riddles file '#{json_file}' not found!"
    return
  end
  
  # Load riddles
  puts "Loading riddles from #{json_file}..."
  riddles_dict = load_riddles(json_file)
  puts "Loaded #{riddles_dict.length} riddles."
  puts
  
  # Extract text from the test image
  puts "Extracting text from #{test_image}..."
  puts "-" * 60
  
  # Try different OCR modes to get the best result
  detected_texts = []
  
  # Try PSM mode 6 (uniform block of text) - good for multi-word
  text1 = extract_text_from_image(test_image, 6)
  detected_texts << ["PSM 6 (uniform block)", text1] unless text1.empty?
  
  # Try PSM mode 8 (single word) - good for single words
  text2 = extract_text_from_image(test_image, 8)
  detected_texts << ["PSM 8 (single word)", text2] unless text2.empty?
  
  # Try PSM mode 7 (single text line)
  text3 = extract_text_from_image(test_image, 7)
  detected_texts << ["PSM 7 (single line)", text3] unless text3.empty?
  
  # Try PSM mode 3 (fully automatic page segmentation)
  text4 = extract_text_from_image(test_image, 3)
  detected_texts << ["PSM 3 (automatic)", text4] unless text4.empty?
  
  # Try PSM mode 11 (sparse text - single word or phrase)
  text5 = extract_text_from_image(test_image, 11)
  detected_texts << ["PSM 11 (sparse text)", text5] unless text5.empty?
  
  if detected_texts.empty?
    puts "No text could be extracted from the image."
    puts "This might indicate an OCR issue. Check that Tesseract is installed correctly."
    return
  end
  
  puts "Detected text (using different OCR modes):"
  detected_texts.each do |mode, text|
    puts "  #{mode}: '#{text}'"
  end
  puts
  
  # Try to match against riddles
  puts "Searching for matches in riddles..."
  puts "-" * 60
  
  all_matches = []
  
  detected_texts.each do |mode, detected_text|
    normalized_text = detected_text.strip.downcase
    
    next if normalized_text.empty?
    
    # Exact match
    if riddles_dict.key?(normalized_text)
      answer = riddles_dict[normalized_text]
      all_matches << {
        mode: mode,
        detected: detected_text,
        match_type: 'exact',
        riddle: normalized_text,
        answer: answer
      }
    else
      # Partial match - check if any riddle contains the detected text or vice versa
      riddles_dict.each do |riddle, answer|
        if normalized_text.include?(riddle) || riddle.include?(normalized_text)
          all_matches << {
            mode: mode,
            detected: detected_text,
            match_type: 'partial',
            riddle: riddle,
            answer: answer
          }
          break
        end
      end
    end
  end
  
  if all_matches.empty?
    puts "No matches found in riddles database."
    puts
    puts "Detected texts were:"
    detected_texts.each do |mode, text|
      puts "  - #{text}"
    end
    puts
    puts "Suggestions:"
    puts "- Check if the detected text is correct"
    puts "- The riddle might not be in the database"
    puts "- Try adjusting OCR settings or image preprocessing"
  else
    puts "Found #{all_matches.length} match(es):"
    puts
    all_matches.each_with_index do |match, idx|
      puts "Match #{idx + 1}:"
      puts "  OCR Mode: #{match[:mode]}"
      puts "  Detected Text: '#{match[:detected]}'"
      puts "  Match Type: #{match[:match_type]}"
      puts "  Riddle: '#{match[:riddle]}'"
      puts "  Answer: #{match[:answer]}"
      puts
    end
    
    # Show the best match (exact matches preferred)
    exact_matches = all_matches.select { |m| m[:match_type] == 'exact' }
    if !exact_matches.empty?
      best_match = exact_matches.first
      puts "=" * 60
      puts "BEST MATCH (Exact):"
      puts "  Riddle: '#{best_match[:riddle]}'"
      puts "  Answer: #{best_match[:answer]}"
      puts "=" * 60
    else
      best_match = all_matches.first
      puts "=" * 60
      puts "BEST MATCH (Partial):"
      puts "  Detected: '#{best_match[:detected]}'"
      puts "  Riddle: '#{best_match[:riddle]}'"
      puts "  Answer: #{best_match[:answer]}"
      puts "=" * 60
    end
  end
end

# Run the test
if ARGV[0] == '--test-image'
  # Test mode: test against a specific image file
  test_riddle_match
else
  # Run the monitor script
  require_relative 'monitor_riddles'
  
  json_file = 'riddles.json'
  
  puts "Loading riddles..."
  riddles_dict = load_riddles(json_file)
  puts "Loaded #{riddles_dict.length} riddles.\n"
  
  # Run the monitor with debug mode enabled for testing
  monitor_screen(riddles_dict, 1.0, nil, nil, true)
end

