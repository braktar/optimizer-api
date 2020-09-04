# Copyright © Mapotempo, 2016
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
require 'csv'
require 'date'
require 'digest/md5'
require 'grape'
require 'grape-swagger'
require 'charlock_holmes'

require './api/v01/api_base'
require './api/v01/entities/status'
require './api/v01/entities/vrp_result'
require './api/v01/resources/submit'
require './api/v01/resources/jobs'

module Api
  module V01
    module CSVParser
      def self.call(object, _env)
        unless object.valid_encoding?
          detection = CharlockHolmes::EncodingDetector.detect(object)
          return false if !detection[:encoding]

          object = CharlockHolmes::Converter.convert(object, detection[:encoding], 'UTF-8')
        end
        line = object.lines.first
        split_comma, split_semicolon, split_tab = line.split(','), line.split(';'), line.split("\t")
        _split, separator = [[split_comma, ',', split_comma.size], [split_semicolon, ';', split_semicolon.size], [split_tab, "\t", split_tab.size]].max_by{ |a| a[2] }
        CSV.parse(object.force_encoding('utf-8'), col_sep: separator, headers: true).collect{ |row|
          r = row.to_h
          new_r = r.clone

          r.each_key{ |key|
            next unless key.include?('.')

            part = key.split('.', 2)
            new_r.deep_merge!(part[0] => { part[1] => r[key] })
            new_r.delete(key)
          }
          r = new_r

          json = r['json']
          if json # Open the secret short cut
            r.delete('json')
            r.deep_merge!(JSON.parse(json))
          end

          r.with_indifferent_access
        }
      end
    end

    class Vrp < APIBase
      include Grape::Extensions::Hash::ParamBuilder

      parser :csv, CSVParser

      namespace :vrp do
        mount Submit
        mount Jobs
      end
    end
  end
end
