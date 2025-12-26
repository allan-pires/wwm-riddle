# Riddle Monitor Script

This script monitors your entire screen to find a specific pattern (`riddle-match.png`). When it detects the pattern, it extracts text from the area above it using OCR (Optical Character Recognition) and matches it against riddles in `riddles.json`. When a match is found, it prints the corresponding answer.

## Setup

1. **Install Ruby dependencies:**
   ```bash
   bundle install
   ```
   
   Or install manually:
   ```bash
   gem install rtesseract mini_magick
   ```

2. **Install Tesseract OCR:**
   
   The script requires Tesseract OCR to be installed on your system:
   
   - **Windows**: Download and install from [GitHub releases](https://github.com/UB-Mannheim/tesseract/wiki)
   - **macOS**: `brew install tesseract`
   - **Linux**: `sudo apt-get install tesseract-ocr` (Debian/Ubuntu) or `sudo yum install tesseract` (RHEL/CentOS)

3. **Install ImageMagick (for screen capture):**
   
   The script uses ImageMagick for screen capture:
   
   - **Windows**: Download and install from [ImageMagick website](https://imagemagick.org/script/download.php#windows)
   - **macOS**: `brew install imagemagick`
   - **Linux**: `sudo apt-get install imagemagick` (Debian/Ubuntu) or `sudo yum install ImageMagick` (RHEL/CentOS)

## Usage

Run the script:
```bash
ruby monitor_riddles.rb
```

The script will:
- Continuously capture and monitor your entire screen
- Search for the pattern defined in `riddle-match.png` using template matching
- When the pattern is found, extract text from the area above it using OCR
- Check if the detected text matches any riddle in `riddles.json`
- Print the answer when a match is found

Press `Ctrl+C` to stop the script.

## Configuration

You can adjust the monitoring parameters in the `main` function:
- `check_interval`: Time between screen checks (default: 1.0 seconds)
- `similarity_threshold`: Template matching similarity threshold (default: 0.85, range: 0.0-1.0)
- `text_region_height`: Height of the text region to extract above the match (default: 150 pixels)

## Requirements

- The `riddle-match.png` file must be in the same directory as the script
- This file should contain the pattern/image that appears on screen when a riddle is displayed
