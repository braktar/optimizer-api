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

require 'ai4r'
include Ai4r::Data
include Ai4r::Clusterers
require './lib/osm/overpass.rb'

module Interpreters
  class ClusteringProcess

    def self.split_clusters(services_vrps, job = nil, &block)
      all_vrps = services_vrps.collect{ |service_vrp|
        vrp = service_vrp[:vrp]
        if vrp.preprocessing_max_split_size && vrp.vehicles.size > 1 && vrp.shipments.size == 0 && service_vrp[:problem_size] > vrp.preprocessing_max_split_size &&
        vrp.services.size > vrp.preprocessing_max_split_size
          points = vrp.services.collect.with_index{ |service, index|
            service.activity.point.matrix_index = index
            [service.activity.point.location.lat, service.activity.point.location.lon]
          }

          result_cluster = kmeans_clustering(vrp, 2)

          sub_first = build_partial_vrp(vrp, result_cluster[0])

          sub_second = build_partial_vrp(vrp, result_cluster[1]) if result_cluster[1]

          deeper_search = [{
            service: service_vrp[:service],
            vrp: sub_first,
            fleet_id: service_vrp[:fleet_id],
            problem_size: service_vrp[:problem_size]
          }]
          deeper_search << {
            service: service_vrp[:service],
            vrp: sub_second,
            fleet_id: service_vrp[:fleet_id],
            problem_size: service_vrp[:problem_size]
          } if sub_second
          split_clusters(deeper_search, job)
        else
          {
            service: service_vrp[:service],
            vrp: vrp,
            fleet_id: service_vrp[:fleet_id],
            problem_size: service_vrp[:problem_size]
          }
        end
      }.flatten
    rescue => e
      puts e
      puts e.backtrace
      raise
    end

    def self.kmeans_clustering(vrp, n)
      vector = vrp.services.collect{ |service|
        [service.id, service.activity.point.location.lat, service.activity.point.location.lon]
      }
      data_set = DataSet.new(data_items: vector.size.times.collect{ |i| [i] })
      c = KMeans.new
      c.set_parameters(max_iterations: 100)
      c.centroid_function = lambda do |data_sets|
        data_sets.collect{ |data_set|
          data_set.data_items.min_by{ |i|
            data_set.data_items.sum{ |j|
              c.distance_function.call(i, j)**2
            }
          }
        }
      end

      c.distance_function = lambda do |a, b|
        a = a[0]
        b = b[0]
        Math.sqrt((vector[a][1] - vector[b][1])**2 + (vector[a][2] - vector[b][2])**2)
      end

      clusterer = c.build(data_set, n)

      result = clusterer.clusters.collect{ |cluster|
        cluster.data_items.collect{ |i|
          vector[i[0]][0]
        }
      }
      puts "Split #{vrp.services.size} into #{result[0].size} & #{result[1] ? result[1].size : 0}"
      result
    end

    def self.dbscan_clustering(service_vrp, job, &block)
      if service_vrp[:vrp].preprocessing_max_split_size && service_vrp[:vrp].vehicles.size > 1 && service_vrp[:vrp].shipments.empty? &&
         service_vrp[:problem_size] > service_vrp[:vrp].preprocessing_max_split_size &&
         service_vrp[:vrp].services.size > service_vrp[:vrp].preprocessing_max_split_size

        polygons = generate_polygons(service_vrp[:vrp])
        # Define segragate dimensions
        unit_sets = service_vrp[:vrp].vehicles.collect{ |vehicle| vehicle.capacities.sort(&:unit_id).collect(&:unit_id) }.uniq
        intersections = unit_sets.inject(:&)
        unit_sets.collect!{ |set| set - intersections }.compact!
        unit_sets.uniq! if unit_sets
        data_items = service_vrp[:vrp].services.collect{ |service|
          service_data = [service.activity.point.location.lat, service.activity.point.location.lon]
          if service.activity.timewindows && !service.activity.timewindows.empty?
            service_data << ((service.activity.timewindows.first[:start] || 0)..(service.activity.timewindows.last[:end] || 2**56))
          else
            service_data << (0..2**56)
          end
          service_data += unit_sets.collect{ |unit| service.quantities.one?{ |quantity| quantity.unit_id == unit } ? 1 : 0 }
          service_data
        }

        custom_distance = lambda do |a, b|
          r = 6378.137
          deg2rad_lat_a = a[0] * Math::PI / 180
          deg2rad_lat_b = b[0] * Math::PI / 180
          deg2rad_lon_a = a[1] * Math::PI / 180
          deg2rad_lon_b = b[1] * Math::PI / 180
          lat_distance = deg2rad_lat_b - deg2rad_lat_a
          lon_distance = deg2rad_lon_b - deg2rad_lon_a

          intermediate = Math.sin(lat_distance / 2) * Math.sin(lat_distance / 2) + Math.cos(deg2rad_lat_a) * Math.cos(deg2rad_lat_b) *
                         Math.sin(lon_distance / 2) * Math.sin(lon_distance / 2)

          fly_distance = 1000 * r * 2 * Math.atan2(Math.sqrt(intermediate), Math.sqrt(1 - intermediate))
          units_distance = (0..unit_sets.size - 1).any? { |index| a[3 + index] + b[3 + index] == 1 } ? 2**56 : 0
          timewindows_distance = a[2].overlaps?(b[2]) ? 0 : 2**56
          fly_distance + units_distance + timewindows_distance
        end

        c = DBSCAN.new
        # Edit DBSCAN parameters
        c.distance_function = custom_distance
        c.epsilon = 4000
        clusterer = c.build(DataSet.new(data_items: data_items))
        clusters = Array.new(clusterer.clusters.size)
        clusterer.labels.each.with_index{ |label, index|
          if label != :noise
            clusters[label - 1] = [] if clusters[label - 1].nil?
            clusters[label - 1] << service_vrp[:vrp].services[index].id
          end
        }

        problems = clusters.compact.collect{ |cluster|
          new_vrp = build_partial_vrp(service_vrp[:vrp], cluster, [service_vrp[:vrp].vehicles.first.id])
          new_vrp.preprocessing_max_split_size = nil

          new_vrp.resolution_duration = ((cluster.size.to_f / service_vrp[:problem_size]) * service_vrp[:vrp].resolution_duration).to_i
          new_vrp.resolution_initial_time_out = ((cluster.size.to_f / service_vrp[:problem_size]) * service_vrp[:vrp].resolution_initial_time_out).to_i

          {
            service: service_vrp[:service],
            vrp: new_vrp,
            fleet_id: nil,
            problem_size: cluster.size
          }
        }
        unassigned = c.labels.collect.with_index{ |label, index|
          if label == :noise
            service_vrp[:vrp].services[index].id
          end
        }.compact

        #From optimizerWrapper
        result = OptimizerWrapper.define_process(problems, [], job){ block }
        merged_routes = {}
        unformed_vrp = Marshal.load(Marshal.dump(service_vrp[:vrp]))
        combined_services = unassigned + result[:unassigned].collect{ |mission| mission[:service_id] }.compact +
                            result[:routes].collect.with_index{ |route, index|
          new_service = Marshal.load(Marshal.dump(problems[index][:vrp].services.first))
          new_service.id = "cumulated_#{index}"
          route_service_ids = route[:activities].collect{ |mission| mission[:service_id] }.compact
          merged_routes["cumulated_#{index}"] = route_service_ids
          new_service.activity.duration = route[:activities][-2][:departure_time].to_i + route[:activities][-1][:travel_time].to_i -
                                          route[:activities][1][:begin_time].to_i + route[:activities][1][:travel_time].to_i
          unformed_vrp.services << new_service
          unformed_vrp.units.each{ |unit|
            associated_quantity = new_service.quantities.find{ |quantity| quantity.id == unit.id }
            if associated_quantity
              associated_quantity.value = 0
            else
              {
                unit: unit,
                unit_id: unit.id,
                value: 0
              }
            end
          }
          service_vrp[:vrp].services.select{ |service| route_service_ids.include?(service.id) }.each{ |service|
            service.quantities.each{ |quantity| new_service.quantities.find{ |new_quantity| new_quantity.unit.id == quantity.unit.id }.value += quantity.value }
          }
          new_service.id
        }

        combined_vrp = build_partial_vrp(unformed_vrp, combined_services)
        new_service_vrp = {
          service: service_vrp[:service],
          vrp: combined_vrp,
          fleet_id: nil,
          problem_size: combined_vrp.services.size
        }
        new_result = OptimizerWrapper.define_process([new_service_vrp], [], job){ block }
        new_result[:routes].collect{ |route|
          route_service_ids = []
          vehicle_id = route[:vehicle_id]
          route[:activities].each{ |activity|
            if activity[:service_id]
              if merged_routes.key?(activity[:service_id])
                route_service_ids += merged_routes[activity[:service_id]]
              else
                route_service_ids << activity[:service_id]
              end
            end
          }
          final_route_vrp = build_partial_vrp(service_vrp[:vrp], route_service_ids, [vehicle_id])
          final_route_vrp.preprocessing_max_split_size = nil

          final_route_vrp.resolution_duration = ((final_route_vrp.services.size.to_f / service_vrp[:problem_size]) * service_vrp[:vrp].resolution_duration).to_i
          final_route_vrp.resolution_initial_time_out = ((final_route_vrp.services.size.to_f / service_vrp[:problem_size]) * service_vrp[:vrp].resolution_initial_time_out).to_i

          new_service_vrp = {
            service: service_vrp[:service],
            vrp: final_route_vrp,
            fleet_id: nil,
            problem_size: final_route_vrp.services.size
          }
        }
      else
        service_vrp
      end
    rescue => e
      puts e
      puts e.backtrace
      raise
    end

    def display_clusters(vrp)
      solution = {
        routes: vrp.vehicles.collect{ |vehicle|
          {
            vehicle_id: vehicle.id,
            activities: []
          }
        }
      }
      @labels.each_with_index{ |cluster_index, service_index|
        next if cluster_index == :noise || cluster_index >= vrp.vehicles.size
        # puts "#{cluster_index} #{service_index}"
        current_route = solution[:routes].find{ |route| route[:vehicle_id] == vrp.vehicles[cluster_index-1].id }
        current_service = vrp.services[service_index]
        current_route[:activities].push({
          service_id: current_service.id
        })
      }
      solution[:unassigned] = @labels.collect.with_index{ |label, index|
        { service_id: vrp.services[index] } if label == :noise
      }.compact
      solution
    end

    def self.generate_polygons(vrp)
      min_lat, min_lon, max_lat, max_lon = nil
      if vrp.points.all?{ |point| point.location.lat && point.location.lon }
        vrp.points.each{ |point|
          min_lat = [min_lat, point.location.lat].compact.min
          min_lon = [min_lon, point.location.lon].compact.min
          max_lat = [max_lat, point.location.lat].compact.max
          max_lon = [max_lon, point.location.lon].compact.max
        }
        bbox = {
          n: max_lat,
          s: min_lat,
          w: min_lon,
          e: max_lon
        }
        overpass = Interpreters::Overpass.new
        overpass.process(bbox)
      end
    end

    def self.route_details(route, vehicle)
      previous = nil
      details = nil
      segments = route.collect{ |lat, lon|
          current = [lat, lon]
          segment = [previous.first, previous.last, lat, lon] if previous
          previous = current
          segment
      }.compact
      if !segments.empty?
        details = OptimizerWrapper.router.compute_batch(OptimizerWrapper.config[:router][:url],
          vehicle[:router_mode].to_sym, vehicle[:router_dimension], segments, false, vehicle.router_options)
        raise RouterWrapperError unless details
      end
      details
    end

    def self.build_partial_vrp(vrp, cluster_services, cluster_vehicles = nil)
      sub_vrp = Marshal::load(Marshal.dump(vrp))
      sub_vrp.id = Random.new
      services = vrp.services.select{ |service| cluster_services.include?(service.id) }.compact
      points_ids = services.map{ |s| s.activity.point.id }.uniq.compact
      sub_vrp.services = services
      points = sub_vrp.services.collect.with_index{ |service, i|
        service.activity.point.matrix_index = i
        [service.activity.point.location.lat, service.activity.point.location.lon]
      }
      if cluster_vehicles
        sub_vrp.vehicles.select!{ |vehicle| cluster_vehicles.include?(vehicle.id) }
      end
      sub_vrp.points = (vrp.points.select{ |p| points_ids.include? p.id } + sub_vrp.vehicles.collect{ |vehicle| [vehicle.start_point, vehicle.end_point] }.flatten ).compact.uniq
      sub_vrp
    end
  end
end
