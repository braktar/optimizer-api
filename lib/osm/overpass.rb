# Copyright © Mapotempo, 2018
#
# This file is part of Mapotempo.
#
# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.
#
# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>
#

require 'httpi'
require 'open-uri'
require 'json'

require 'open3'
require 'thread'

require 'overpass_api_ruby'
require 'pg'

module Interpreters
  class Overpass
    def initialize
      @semaphore = Mutex.new
    end
    def process(bbox)
      id = rand(1e10)
      timeout = 9000
      maxsize = 1073741824
      endpoint = 'http://overpass-api.de/api/interpreter'

      n = bbox[:n]
      s = bbox[:s]
      w = bbox[:w]
      e = bbox[:e]

      bounding_box = "#{s},#{w},#{n},#{e}"

      query = "(
        way
          ['waterway'='river']
          (#{bounding_box});
        way
          ['highway'='motorway']
          (#{bounding_box});
        way
          ['highway'='motorway_link']
          (#{bounding_box});
        way
          ['highway'='trunk']
          (#{bounding_box});
        way
          ['highway'='trunk_link']
          (#{bounding_box});
        way
          ['natural'='coastline']
          (#{bounding_box});
      );
      (._;>;);out meta;"

      puts query

      header = ""
      header << "[bbox:#{bounding_box}]" if bbox
      header << "[timeout:#{timeout}]" if timeout
      header << "[maxsize:#{maxsize}]" if maxsize

      header << "[out:xml]"

      overpass_query = "#{header};#{query}"

      url = URI::encode("#{endpoint}?data=#{overpass_query}")
      r = HTTPI::Request.new(url)
      response = HTTPI.get(r).body

      input = Tempfile.new(['response_overpass', '.osm'], tmpdir=@tmp_dir)
      # input = File.open('response_overpass.osm', "r")
      # input = File.new('response_overpass.osm', "w+")
      input.write(response)
      input.close

      db = PG::Connection.new(nil, 5432, nil, nil, 'osm', nil, nil)

      cmd = "imposm --write -d osm --host 'localhost' --read '#{input.path}' -m 'lib/osm/imposm_profile.py' --table-prefix 'osm_#{id}' --overwrite-cache"

      puts cmd
      system(cmd)

      db.exec("CREATE TABLE osm_#{id}_lines (
                  id SERIAL PRIMARY KEY,  geometry geometry(LineString, 4326));")
      db.exec("CREATE TABLE osm_#{id}_polygons (
                  id SERIAL PRIMARY KEY,  geometry geometry(Polygon, 4326));")
                  #id SERIAL PRIMARY KEY,  geometry geometry(GeometryCollection, 4326));")
                  #id SERIAL PRIMARY KEY,  geometry geometry(Polygon, 4326));")

      db.exec("INSERT INTO osm_#{id}_lines (geometry)
              SELECT ST_GeomFromText('LINESTRING(#{w} #{n}, #{e} #{n}, #{e} #{s})', 4326);")
      db.exec("INSERT INTO osm_#{id}_lines (geometry)
                SELECT ST_GeomFromText('LINESTRING(#{e} #{s}, #{w} #{s}, #{w} #{n})', 4326);")
      db.exec("INSERT INTO osm_#{id}_lines (geometry)
                SELECT geometry
                FROM osm_#{id}_motorways;")
      db.exec("INSERT INTO osm_#{id}_lines (geometry)
                SELECT geometry
                FROM osm_#{id}_waterways;")
      db.exec("INSERT INTO osm_#{id}_lines (geometry)
                SELECT geometry
                FROM osm_#{id}_railways;")

      db.exec("INSERT INTO osm_#{id}_polygons (geometry)
                WITH united AS (SELECT st_union(geometry) w FROM osm_#{id}_lines),
                polied AS (SELECT ST_Polygonize(w) w FROM united)
                SELECT (st_dump(w)).geom poly FROM polied")
                # SELECT (st_dump(w)).geom poly FROM polied")
                # SELECT (w) poly FROM polied")
      polygons = db.exec("SELECT ST_AsGeoJSON(geometry)
                FROM osm_#{id}_polygons").values.collect{ |element| element.first }

      db.exec("DROP TABLE osm_#{id}_lines, osm_#{id}_polygons")
      db.exec("DROP TABLE osm_#{id}_motorways, osm_#{id}_railways, osm_#{id}_waterways CASCADE")

      polygons
      # raise 'STOP'
    ensure
      db && db.close
      input && input.unlink
    end
  end
end
