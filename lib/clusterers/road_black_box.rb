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
require './lib/clusterers/cluster_problem_pb.rb'
module Clusterers
  class RoadBlackBox
    def self.build(vrp, options = {})
      vehicles = vrp.vehicles.collect.with_index{ |vehicle, index|
        ClusterVrp::Vehicle.new(
          name: vehicle.id,
          capacities: vrp.units.collect{ |unit|
            q = vehicle.capacities.find{ |capacity| capacity.unit_id == unit.id }
            ClusterVrp::Capacity.new(
              limit: (q && q.limit && q.limit < 1e+22) ? q.limit : -1,
              load: 0
            )
          },
          start_location: ClusterVrp::Location.new(
            lat: vehicle.start_point.location.lat,
            lon: vehicle.start_point.location.lon,
            matrix_index: vehicle.start_point.matrix_index
          ),
          end_location: ClusterVrp::Location.new(
            lat: vehicle.end_point.location.lat,
            lon: vehicle.end_point.location.lon,
            matrix_index: vehicle.end_point.matrix_index
          ),
          duration: vehicle.duration,
          duration_load: 0
        )
      }

      services = vrp.services.map{ |service|
        vehicles_indices = if !service[:skills].empty? && (vrp.vehicles.all? { |vehicle| vehicle.skills.empty? }) && service[:unavailable_visit_day_indices].empty?
          []
        else
          vrp.vehicles.collect.with_index{ |vehicle, index|
            if service.skills.empty? || !vehicle.skills.empty? && ((vehicle.skills[0] & service.skills).size == service.skills.size)
              index
            end
          }.compact
        end

        ClusterVrp::Service.new(
          name: service.id,
          quantities: vrp.units.collect{ |unit|
            q = service.quantities.find{ |quantity| quantity.unit == unit }
            q&.value || 0
          },
          duration: service.activity.duration,
          vehicle_indices: (service.sticky_vehicles.size > 0 && service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact.size > 0) ?
            service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact : vehicles_indices,
          location: ClusterVrp::Location.new(
            lat: service.activity.point.location.lat,
            lon: service.activity.point.location.lon,
            matrix_index: service.activity.point&.matrix_index
          )
        )
      }

      config = ClusterVrp::Options.new(
        intermediate_states: options[:debug],
        distance: 'euclidean',
        cut_index: vrp.units.index{ |unit| unit.id == options[:cut_symbol] } || vrp.units.size
      )

      problem = ClusterVrp::Problem.new(
        options: config,
        vehicles: vehicles,
        services: services,
        matrices: nil,
        solutions: []
      )

      input = Tempfile.new('blackbox-input', @tmp_dir)
      input.write(ClusterVrp::Problem.encode(problem))
      input.close

      # cmd = [@@c[:roadblackbox], input.path].join(' ')
      # log cmd
      # system(cmd)

      indices = nil
      date_time = DateTime.now
      clusters, loads = nil, nil
      unless $CHILD_STATUS.nil?
        if $CHILD_STATUS.exitstatus.zero?
          content = ClusterVrp.decode(output.read)
          output.rewind
          solution_index = 0
          content.solutions.each.with_index{ |solution, solution_index|
            indices = solution.assignment

            clusters = Array.new(vrp.vehicles.size) { [] }
            loads = Array.new(vrp.vehicles.size) { 0 }
            indices.each.with_index{ |cluster_index, index|
              service = vrp.services[index]
              clusters[cluster_index] << service
              loads[cluster_index] += options[:cut_symbol] == :duration ? service.activity.duration : service.quantities.find{ |q| q.unit_id == options[:cut_symbol] }.value
            }
            if options[:debug]
              polygons = clusters.map{ |cluster| collect_hulls(cluster) }
              Api::V01::APIBase.dump_vrp_dir.write("#{date_time}-#{solution_index}.geojson", {
                type: 'FeatureCollection',
                features: polygons.compact
              }.to_json)
            end
          }
        end
      end
      [clusters, loads]
    ensure
      input&.unlink
    end

    def self.collect_hulls(cluster)
      loads = Hash.new{ 0 }
      vector = cluster.map{ |service|
        service.quantities.each{ |quantity|
          quantities[quantity.unit_id] += quantity.value
        }
        loads[:duration] += service.activity.duration

        [service.activity.point.lon, service.activity.point.lat]
      }
      hull = Hull.get_hull(vector)
      {
        type: 'Feature',
        properties: loads.map{ |unit_id, value|
          {
            unit_id: unit_id,
            value: value
          }
        },
        geometry: {
          type: 'Polygon',
          coordinates: [hull + [hull.first]]
        }
      }
    end
  end
end
