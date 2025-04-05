#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'
require 'polylines'

# Create directories for images, video, and output
IMAGES_DIR = 'images'
OUTPUT_DIR = 'output'
FileUtils.mkdir_p(IMAGES_DIR)
FileUtils.mkdir_p(OUTPUT_DIR)

# API key (using the same key from compute_route.rb)
API_KEY = 'AIzaSyDfByKJHl0ivRhAL5UcnkN5aTXzhf64zqI'

# Step 1: Get the encoded polyline from the route
def get_encoded_polyline
  # API endpoint
  uri = URI.parse('https://routes.googleapis.com/directions/v2:computeRoutes')

  # Create HTTP object
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  # Create request
  request = Net::HTTP::Post.new(uri.request_uri)
  request['Content-Type'] = 'application/json'
  request['X-Goog-Api-Key'] = API_KEY
  request['X-Goog-FieldMask'] = 'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline'

  request_body = {
    origin: {
      location: {
        latLng: {
          latitude: 35.66897641953312,
          longitude: 139.62363135889075
        }
      }
    },
    destination: {
      location:{
        latLng: {
          latitude: 35.6585460777285,
          longitude: 139.69855525280985
        }
      }
    },
    travelMode: 'WALK',
    routingPreference: 'ROUTING_PREFERENCE_UNSPECIFIED',
    computeAlternativeRoutes: false,
    routeModifiers: {
      avoidTolls: false,
      avoidHighways: false,
      avoidFerries: false
    },
    languageCode: 'en-US',
    units: 'METRIC',
    polylineQuality: 'HIGH_QUALITY',
  }

  request.body = request_body.to_json

  # Make the request
  begin
    response = http.request(request)

    if response.code == '200'
      result = JSON.parse(response.body)
      puts "Route computed successfully"

      if result['routes'] && !result['routes'].empty?
        route = result['routes'][0]
        puts "Distance: #{route['distanceMeters']} meters"
        puts "Duration: #{route['duration'].sub('s', '')} seconds" if route['duration']

        if route['polyline'] && route['polyline']['encodedPolyline']
          return route['polyline']['encodedPolyline']
        else
          puts "Error: No encoded polyline found in the response"
          return nil
        end
      end
    else
      puts "Error: #{response.code}"
      puts response.body
      return nil
    end
  rescue StandardError => e
    puts "Exception: #{e.message}"
    return nil
  end
end

# Step 2: Decode the polyline to get coordinates
def decode_polyline(encoded_polyline)
  puts "Decoding polyline..."
  coordinates = Polylines::Decoder.decode_polyline(encoded_polyline)
  puts "Decoded #{coordinates.length} coordinates from polyline"

  # Use all coordinates for a smoother hyperlapse
  # The original polyline has #{coordinates.length} points which should provide a good hyperlapse
  puts "Using all #{coordinates.length} coordinates for a smoother hyperlapse"

  # Save coordinates to output/coordinates.json
  save_coordinates_to_json(coordinates)

  return coordinates
end

# Save coordinates to JSON file
def save_coordinates_to_json(coordinates)
  puts "Saving coordinates to output/coordinates.json..."

  # Format coordinates as array of objects with ID and coordinates
  formatted_coordinates = coordinates.each_with_index.map do |coord, index|
    {
      "id" => index.to_s.rjust(4, '0'),
      "coordinates" => coord
    }
  end

  # Convert to JSON with pretty formatting
  coordinates_json = JSON.pretty_generate(formatted_coordinates)

  # Write to file
  File.open(File.join(OUTPUT_DIR, 'coordinates.json'), 'w') do |file|
    file.write(coordinates_json)
  end

  puts "Coordinates saved successfully"
end

# Calculate bearing between two points
def calculate_bearing(start_point, end_point)
  start_lat, start_lng = start_point
  end_lat, end_lng = end_point

  # Convert to radians
  start_lat_rad = start_lat * Math::PI / 180
  start_lng_rad = start_lng * Math::PI / 180
  end_lat_rad = end_lat * Math::PI / 180
  end_lng_rad = end_lng * Math::PI / 180

  # Calculate bearing
  y = Math.sin(end_lng_rad - start_lng_rad) * Math.cos(end_lat_rad)
  x = Math.cos(start_lat_rad) * Math.sin(end_lat_rad) -
      Math.sin(start_lat_rad) * Math.cos(end_lat_rad) * Math.cos(end_lng_rad - start_lng_rad)
  bearing_rad = Math.atan2(y, x)

  # Convert to degrees
  bearing_deg = (bearing_rad * 180 / Math::PI + 360) % 360

  return bearing_deg
end

# Step 3: Fetch Street View images for each coordinate
def fetch_street_view_images(coordinates)
  puts "Fetching Street View images..."

  # Street View API parameters
  size = "600x400"  # Image size
  fov = 90          # Field of view
  pitch = 0         # Angle (0 = horizontal, 90 = up, -90 = down)

  coordinates.each_with_index do |coord, index|
    lat, lng = coord

    # Calculate heading based on direction of movement
    if index < coordinates.length - 1
      # If not the last point, calculate bearing to the next point
      heading = calculate_bearing(coord, coordinates[index + 1])
    elsif index > 0
      # If last point, use the bearing from the previous point
      heading = calculate_bearing(coordinates[index - 1], coord)
    else
      # Default heading if only one point (shouldn't happen)
      heading = 0
    end

    puts "Point #{index + 1}: Heading #{heading.round(2)} degrees"

    # Construct the Street View API URL
    url = "https://maps.googleapis.com/maps/api/streetview?size=#{size}&location=#{lat},#{lng}&fov=#{fov}&heading=#{heading}&pitch=#{pitch}&key=#{API_KEY}"

    # Create a filename for the image
    filename = File.join(IMAGES_DIR, "streetview_#{index.to_s.rjust(4, '0')}.jpg")

    # Fetch the image
    begin
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)

      if response.code == "200"
        File.open(filename, "wb") do |file|
          file.write(response.body)
        end
        puts "Downloaded image #{index + 1}/#{coordinates.length}: #{filename}"
      else
        puts "Error downloading image #{index + 1}: HTTP #{response.code}"
      end
    rescue StandardError => e
      puts "Exception downloading image #{index + 1}: #{e.message}"
    end

    # Add a small delay to avoid hitting API rate limits
    sleep(0.2)
  end
end

# Step 4: Generate a video from the images using FFmpeg
def generate_video
  puts "Generating video..."

  # Check if FFmpeg is installed
  unless system("which ffmpeg > /dev/null 2>&1")
    puts "Error: FFmpeg is not installed. Please install FFmpeg to generate the video."
    return false
  end

  # First, let's count how many images we have
  image_count = Dir.glob("#{IMAGES_DIR}/streetview_*.jpg").count
  puts "Found #{image_count} images to process"

  if image_count < 2
    puts "Error: At least 2 images are required to create a video"
    return false
  end

  # Create the video with motion compensated interpolation for smoother transitions
  puts "Creating video from images with motion compensated interpolation..."
  final_cmd = "ffmpeg -y -framerate 30 -pattern_type glob -i \"#{IMAGES_DIR}/streetview_*.jpg\" " \
              "-vf \"minterpolate=mi_mode=mci:mc_mode=aobmc:me_mode=bidir:me=epzs:vsbmc=1\" " \
              "-c:v libx264 -pix_fmt yuv420p -crf 18 hyperlapse.mp4"

  if system(final_cmd)
    puts "Video generated successfully: hyperlapse.mp4"
    return true
  else
    puts "Error generating video"
    return false
  end
end

# Parse command line arguments
def parse_args
  options = { skip_fetch: false }

  ARGV.each do |arg|
    case arg
    when '--skip-fetch', '-s'
      options[:skip_fetch] = true
      puts "Skipping image fetching, using existing images in #{IMAGES_DIR} directory"
    when '--only-coordinates', '-c'
      options[:only_coordinates] = true
      puts "Only saving coordinates to output/coordinates.json"
    when '--help', '-h'
      puts "Usage: #{$PROGRAM_NAME} [options]"
      puts "Options:"
      puts "  --skip-fetch, -s   Skip fetching images and use existing ones in the #{IMAGES_DIR} directory"
      puts "  --only-coordinates, -c   Only save coordinates to output/coordinates.json"
      puts "  --help, -h         Show this help message"
      exit 0
    end
  end

  options
end

# Main execution
puts "Starting hyperlapse generation process..."
options = parse_args

if !options[:skip_fetch]
  # Step 1: Get the encoded polyline
  encoded_polyline = get_encoded_polyline
  if encoded_polyline.nil?
    puts "Failed to get encoded polyline. Exiting."
    exit 1
  end

  # Step 2: Decode the polyline
  coordinates = decode_polyline(encoded_polyline)
  if coordinates.empty?
    puts "Failed to decode polyline. Exiting."
    exit 1
  end

  return if options[:only_coordinates]

  # Step 3: Fetch Street View images
  fetch_street_view_images(coordinates)
else
  # Check if images directory exists and has images
  unless Dir.exist?(IMAGES_DIR) && !Dir.glob("#{IMAGES_DIR}/streetview_*.jpg").empty?
    puts "Error: No images found in #{IMAGES_DIR} directory. Please run without --skip-fetch option first."
    exit 1
  end

  puts "Using existing images in #{IMAGES_DIR} directory"
end



# Step 4: Generate the video
generate_video

puts "Process completed!"
