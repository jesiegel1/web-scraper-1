#!/usr/bin/env ruby
require 'phantomjs'
require 'capybara/poltergeist'

Capybara.register_driver :poltergeist do |app|
  Capybara::Poltergeist::Driver.new(app, js_errors: false)
end

Capybara.default_driver = :poltergeist

################################################################################

require 'net/http'
require 'uri'
require 'json'
require 'nokogiri'
require 'csv'
require 'Indirizzo'

puts "How many rows should be fetched?"
number_of_rows = gets.chomp
puts "Please enter a name for your output file."
output_file = gets.chomp
puts "Please enter the root url being scraped (the main url without any additional parameters: http://<some_url>.com)."
root_url = gets.chomp
puts "Please enter the full url being scraped."
main_url = gets.chomp

run_scraper(number_of_rows, output_file, root_url, main_url)

@number_of_rows = nil
@output_file = nil
@root_url = nil
@main_url = nil
@urls = nil
@htmls = nil
@browser = nil
@url1 = nil
@url2 = nil
@cookies = nil

def wait_for_ajax
  start = Time.now
  while (@browser.driver.network_traffic.select { |request| request.url.include?("increment") }.count == 0) || (@browser.driver.network_traffic.select { |request| request.url.include?("startRow") }.count == 0)
    raise "Timed out waiting for poltergeist traffic to finish up #{@browser.driver.network_traffic}" if Time.now - start > 20
    @browser.driver.scroll_to(0,5000)
    sleep 1.0
  end
end

# Get cookies and ajax urls
def setup
  @urls = []
  @htmls = []
  @browser = Capybara.current_session
  @browser.visit(@main_url)
  @browser.driver.scroll_to(0,600)
  wait_for_ajax()
  @url1 = @browser.driver.network_traffic.select { |request| request.url.include?("increment") }.first.url
  @url2 = @browser.driver.network_traffic.select { |request| request.url.include?("startRow") }.first.url

  @cookies = ""
  @browser.driver.cookies.each { |key, value| @cookies << "#{value.name}=#{value.value}; " }
  @cookies.strip!
end

# Fetch initial search results
def get_first_html
  uri = URI.parse(@url1)
  request = Net::HTTP::Get.new(uri)
  request["Cookie"] = @cookies
  request["Accept-Language"] = "en-US,en;q=0.8"
  request["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.103 Safari/537.36"
  request["Accept"] = "*/*"
  request["Referer"] = @main_url
  request["X-Requested-With"] = "XMLHttpRequest"
  request["Connection"] = "keep-alive"

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.read_timeout = 10000
    http.request(request)
  end

  if response.code == 500
    get_first_html
  end

  puts response.code
  return response
end

# Fetch remaining lazy-loaded results
def get_next_html(start_row, end_row)

  @url2.gsub!(/(?:startRow=)[0-9]+/, "startRow=#{start_row}")
  @url2.gsub!(/(?:endRow=)[0-9]+/, "endRow=#{end_row}")

  uri2 = URI.parse(@url2)
  request2 = Net::HTTP::Get.new(uri2)
  request2["Cookie"] = @cookies
  request2["Accept-Language"] = "en-US,en;q=0.8"
  request2["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.103 Safari/537.36"
  request2["Accept"] = "application/json, text/javascript, */*; q=0.01"
  request2["Referer"] = @main_url
  request2["X-Requested-With"] = "XMLHttpRequest"
  request2["Connection"] = "keep-alive"

  response2 = Net::HTTP.start(uri2.hostname, uri2.port, use_ssl: uri2.scheme == "https") do |http|
    http.read_timeout = 10000
    http.request(request2)
  end

  if response2.code == 500
    get_next_html(start_row, end_row)
  end

  puts response2.code
  return response2
end

# Parse initial search results
def parse_first_html(html, csv)
  tbody = html.xpath("//tbody")
  rows = tbody.xpath(".//tr")
  rows.each do |row|
    columns = row.xpath(".//td")
    array = []
    columns.shift
    columns.pop
    columns.each do |column|
      array << column.text.gsub(/\\r/," ").gsub(/\\t/," ").gsub(/\\n/," ").strip
    end
    href = columns.first.xpath(".//a").first["href"]
    href.gsub!(/\\"/, "")
    url_path = @root_url + href
    more_info(url_path, array)
    csv << array
  end
end

# Parse remaining lazy-loaded results
def parse_rest_of_html(html, csv)
  rows2 = html.xpath("//tr")
  rows2.each do |row|
    columns = row.xpath(".//td")
    array = []
    columns.shift
    columns.pop
    columns.each do |column|
      array << column.text.gsub(/\\r/," ").gsub(/\\t/," ").gsub(/\\n/," ").strip
    end
    if columns.count > 0
      if columns.first.xpath(".//a").count > 0
        href = columns.first.xpath(".//a").first["href"]
        href.gsub!(/\\"/, "")
        url_path = @root_url + href
        more_info(url_path, array)
      end
    end
    csv << array
  end
end

# Wait for ajax to finish loading
def wait_for_ajax2
  counter = 0
  while @browser.execute_script("return $.active").to_i > 0
    counter += 1
    sleep(0.1)
    raise "AJAX request took longer than 5 seconds." if counter >= 50
  end
end

def assert_data_visible
  wait_until { @browser.find("#jq-exhibitor-details").visible? }
rescue Capybara::TimeoutError
  flunk 'Expected details to be visible.'
end

# Follow each row's link for that row's additional data
def more_info(url, array)
  browser = Capybara.current_session
  browser.visit(url)
  wait_for_ajax2()
  html3 = Nokogiri::HTML(browser.html)
  details = html3.css("#jq-exhibitor-details") # TODO: Add wait until element appears
  info = details.xpath(".//p")[0]
  if info.nil?
    sleep 1
    more_info(url, array)
  end
  text_nodes = info.xpath(".//text()")
  street = Indirizzo::Address.new(text_nodes[0].text).text
  rest_of_address = Indirizzo::Address.new(text_nodes[1].text)
  city = rest_of_address.city.first
  state = rest_of_address.state
  zip = rest_of_address.zip
  phone = ""
  website = ""
  text_nodes.each do |node|
    if node.text.include?("http")
      website = node.text
    elsif node.text.scan(/\d/).count == 10
      phone = node.text.gsub(/[^\d]/, '')
    end
  end
  array.push(street, city, state, zip, phone, website)
end

###############################################################################################

# Takes arguments from GUI input
def run_scraper(number_of_rows, output_file, root_url, main_url)
  @number_of_rows = number_of_rows
  @output_file = output_file.include?("csv") ? output_file : (output_file << ".csv")
  @root_url = root_url
  @main_url = main_url
  setup()
  response = get_first_html()
  @htmls << Nokogiri::HTML(response.body)

  # Increment lazy-loaded results by 100 until all rows have been returned
  @start_row = 101
  @end_row = 200
  while @end_row < @number_of_rows.to_i + 100
    response2 = get_next_html(@start_row, @end_row)
    @htmls << Nokogiri::HTML(response2.body)
    @start_row += 100
    @end_row += 100
  end

  CSV.open(@output_file, "wb") do |csv|
    csv << ["Exhibitors and Brands", "Shows", "Booth(s)", "Street Address", "City", "State", "Zip", "Phone Number", "Website"]
    # Return initial search results from html array
    first_html = @htmls.shift
    # Parse initial search results
    parse_first_html(first_html, csv)
    # Parse remaining lazy-loaded results
    @htmls.each do |html|
      parse_rest_of_html(html, csv)
    end
  end
end




