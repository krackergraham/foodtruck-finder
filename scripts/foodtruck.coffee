# You can get a google maps API key here
# https://developers.google.com/maps/documentation/javascript/get-api-key
GKEY = '##############'   # Google Maps API Key
LAT = '47.6233676'        # WeWork SLU lat and long
LONG = '-122.3306771'


# Convert to a 12 hour format
parseHours = (date) ->
  h = date.getHours()
  m = date.getMinutes();
  if m < 10
    m = "0" + m

  s = 'am'
  if h is 0
    h = 12
  else if h > 12
    h = h % 12
    s = 'pm'

  return h + ':' + m + ' ' + s

# Parse the location string and remove whitespace and replace with '+' per google api requirements
parseLocations = (truckData) ->
  locations = []
  for truck in truckData
    do(truck) ->
      location = truck.Trucklocation.location.trim()  # trim any leading or trailing whitespace
      .replace(/\s\s+/g, ' ')                         # remove multiple spaces and replace with a single space
      .replace(/,/g, '')                              # remove any commas
      .split(' ').join('+')                           # replace spaces with '+'
      locations.push location

  return locations

# Handle the response data from the roaminghunger api
parseTruckData = (data) ->
  trucks = []

  for truckData in data
      do (truckData) ->
        truck = {}
        truck.name = truckData.Truck.name.trim()
        truck.start = parseHours new Date(truckData.Trucklocation.start)
        truck.end = parseHours new Date(truckData.Trucklocation.end)
        truck.location = truckData.Trucklocation.location.replace(/\s\s+/g, ' ')
        trucks.push(truck)

  return trucks

completed = 0;
requested = 0;

# Addresses must be formatted per Google spec
# All spaces should be replaced by '+' and all ',' should be removed
# e.g. 500 Yale Ave -> 500+Yale+Ave
# https://developers.google.com/maps/documentation/distance-matrix/intro#DistanceMatrixRequests
# https://developers.google.com/maps/documentation/javascript/distancematrix
getDistances = (msg, trucks, locations, page) ->
  gKey = GKEY
  origin = "#{LAT},#{LONG}"
  url = "https://maps.googleapis.com/maps/api/distancematrix/json?"

  requested++

  locsForQuery = locations;
  if (locations.length > 25)
    locsForQuery = locations.splice(0, 25);
    if(locations.length > 0)
      getDistances(msg, trucks, locations, page + 1)

  locationsString = ""
  for loc, i in locsForQuery
    do (loc, i) ->
      locationsString += loc
      if(i < locsForQuery.length - 1)
        locationsString += '|'

  msg.http(url)
  .query
    origins: origin,
    destinations: locationsString,
    mode: "walking",
    key: gKey
  .get() (err, res, body) ->
    if err
      msg.send "Error:  #{err} #{err.message}"
      return
    if res && res.statusCode isnt 200
      console.error "Error: #{res.statusCode}: #{body}"
      msg.send "Error: #{res.statusCode}: Unable to retrieve distance data"
      return

    response = JSON.parse body

    if response.status is 'OK'
      completed++
      processDistance trucks, response.rows[0].elements, page
      if(completed is requested)
        msg.send writeTrucks trucks
        requested = 0;
        completed = 0
    else
      msg.send "Unable to retrieve distance data. " + response.status

processDistance = (trucks, elements, page) ->
  for element, i in elements
    do (element) ->
      i = i + (25 * page)
      if element.status is 'OK'
        trucks[i].time = element.duration.text # approximate walking time
        trucks[i].distance = element.distance.value   # distance in meters
      else
        trucks[i].time = 'unknown'
        trucks[i].distance = 'unknown'

writeTrucks = (trucks) ->
  result = ""
  for truck in trucks
    do (truck) ->
      # only write trucks that have a distance less than 2000 m
      if(truck.distance isnt null and truck.distance < 2000)
        result += truck.name +
            ' is at ' + truck.location +
            ' which is about ' + truck.time + ' away' +
            ' and will be there from ' + truck.start +
            ' until ' + truck.end +
            '\r\n'

  if(result is "")
    result = "But it looks like there aren't any nearby :("

  return result

module.exports = (robot) ->
  # Queries http://roaminghunger.com for food truck locations between 11am and 3pm
  robot.respond /food|foodtruck|let's eat|nom nom/, (msg) ->
    now = new Date()
    today = now.getFullYear() + '-' + (now.getMonth() + 1) + '-' + now.getDate()
    startTime = "+11:00:01"
    endTime = "+15:59:59"

    msg.send 'Let me see what there is to eat around here...'

    url = "https://roaminghunger.com/cities/getCityTrucksTimeFrame/sea" +
      "/start:" + today + startTime +
      "/end:" + today + endTime + "/"

    msg.http(url)
    .header('Accept', 'application/json')
    .header('X-Requested-With', 'XMLHttpRequest')
    .get() (err, res, body) ->
      if err
        msg.send 'Error: ' + err

      if res && res.statusCode isnt 200
        console.error "Error: #{res.statusCode}: #{body}"
        msg.send 'Unable to retrieve truck locations. Code: ' + res.statusCode
        return

      truckData = JSON.parse body

      trucks = parseTruckData truckData         # Array of truck objects
      locations = parseLocations truckData      # Concatenated string of locations
      msg.send "I found " + trucks.length + " truck" + if trucks.length isnt 1 then "s"

      getDistances msg, trucks, locations, 0
