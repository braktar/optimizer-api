# Copyright © Mapotempo, 2021
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
require './models/base'

module Models
  class Solution < Base
    field :status
    field :cost, default: 0
    field :elapsed, default: 0
    field :heuristic_synthesis, default: {}
    field :iterations
    field :solvers, default: []
    field :use_deprecated_csv_headers, default: false

    has_many :routes, class_name: 'Models::SolutionRoute'
    has_many :unassigned, class_name: 'Models::RouteActivity'

    belongs_to :cost_details, class_name: 'Models::CostDetails', default: Models::CostDetails.new({})
    belongs_to :details, class_name: 'Models::RouteDetail', default: Models::RouteDetail.new({})

    def as_json(options = {})
      hash = super(options)
      hash.delete('details')
      hash.merge(details.as_json(options))
    end

    def parse_solution(vrp)
      tic_parse_result = Time.now
      vrp.vehicles.each{ |vehicle|
        route = routes.find{ |r| r.vehicle.id == vehicle.id }
        unless route
          # there should be one route per vehicle in solution :
          route = vrp.empty_route(vehicle)
          routes << route
        end
        matrix = vrp.matrices.find{ |mat| mat.id == vehicle.matrix_id }
        route.fill_missing_route_data(vrp, matrix)
      }
      compute_result_total_dimensions_and_round_route_stats

      log "solution - unassigned rate: #{unassigned.size} of (ser: #{vrp.visits} (#{(unassigned.size.to_f / vrp.visits * 100).round(1)}%)"
      used_vehicle_count = routes.count{ |r| r.activities.any?{ |a| a.service_id } }
      log "result - #{used_vehicle_count}/#{vrp.vehicles.size}(limit: #{vrp.resolution_vehicle_limit}) vehicles used: #{used_vehicle_count}"
      log "<---- parse_result elapsed: #{Time.now - tic_parse_result}sec", level: :debug
      self
    end

    def compute_result_total_dimensions_and_round_route_stats
      [:total_time, :total_travel_time, :total_travel_value, :total_distance, :total_waiting_time].each{ |stat_symbol|
        next unless routes.all?{ |r| r.detail.send stat_symbol }

        details.send("#{stat_symbol}=", routes.collect{ |r|
          r.detail.send(stat_symbol)
        }.reduce(:+))
      }
    end

    def +(other)
      self.cost += other.cost
      self.elapsed += other.elapsed
      self.heuristic_synthesis.merge!(other.heuristic_synthesis)
      self.solvers += other.solvers
      self.routes += other.routes
      self.unassigned += other.unassigned
      self.cost_details += other.cost_details
      self.details += other.details
      self
    end
  end
end
