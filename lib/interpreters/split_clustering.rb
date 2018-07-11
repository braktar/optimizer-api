# Copyright © Mapotempo, 2017
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

module Interpreters
  class SplitClustering
    def self.custom_distance(a, b)
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
      # units_distance = (0..unit_sets.size - 1).any? { |index| a[3 + index] + b[3 + index] == 1 } ? 2**56 : 0
      # timewindows_distance = a[2].overlaps?(b[2]) ? 0 : 2**56
      fly_distance #+ units_distance + timewindows_distance
    end

    def self.split_clusters(services_vrps, job = nil, &block)
      all_vrps = services_vrps.collect{ |service_vrp|
        vrp = service_vrp[:vrp]
        if vrp.preprocessing_apply_hierarchical_split
          split_hierarchical(service_vrp, vrp) #give right nb of days : compute it in split_hierarchical ?
        elsif vrp.preprocessing_max_split_size && vrp.vehicles.size > 1 && vrp.shipments.size == 0 && service_vrp[:problem_size] > vrp.preprocessing_max_split_size &&
        vrp.services.size > vrp.preprocessing_max_split_size && !vrp.schedule_range_indices && !vrp.schedule_range_date
          points = vrp.services.collect.with_index{ |service, index|
            service.activity.point.matrix_index = index
            [service.activity.point.location.lat, service.activity.point.location.lon]
          }

          result_cluster = clustering(vrp, 2)

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

    def self.clustering(vrp, n)
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

    def self.build_partial_vrp(vrp, cluster_services)
      sub_vrp = Marshal::load(Marshal.dump(vrp))
      sub_vrp.id = Random.new
      services = vrp.services.select{ |service| cluster_services.include?(service.id) }.compact
      points_ids = services.map{ |s| s.activity.point.id }.uniq.compact
      sub_vrp.services = services
      sub_vrp.points = (vrp.points.select{ |p| points_ids.include? p.id } + vrp.vehicles.collect{ |vehicle| [vehicle.start_point, vehicle.end_point] }.flatten ).compact.uniq
      sub_vrp
    end

    def self.count_metric(graph, parent, symbol)
      value = parent.nil? ? 0 : graph[parent][:unit_metrics][symbol]
      value + (parent.nil? ? 0 : (count_metric(graph, graph[parent][:left], symbol) + count_metric(graph, graph[parent][:right], symbol)))
    end

    def self.remove_from_upper(graph, node, symbol, value_to_remove)
      if graph.key?(node)
        graph[node][:unit_metrics][symbol] -= value_to_remove
        remove_from_upper(graph, graph[node][:parent], symbol, value_to_remove)
      end
    end

    def self.tree_leafs(graph, node)
      if node.nil?
        [nil]
      elsif (graph[node][:level]).zero?
         [node]
       else
         [tree_leafs(graph, graph[node][:left]), tree_leafs(graph, graph[node][:right])]
       end
    end


    def self.tree_leafs_delete(graph, node)
      returned = if node.nil?
        []
      elsif (graph[node][:level]).zero?
        [node]
      else
        [tree_leafs(graph, graph[node][:left]), tree_leafs(graph, graph[node][:right])]
      end
      graph.delete(node)
      returned
    end

    def self.split_hierarchical(service_vrp, vrp, cut_symbol = :duration)
      nb_clusters = vrp.vehicles.collect{ |vehicle| vehicle.sequence_timewindows && vehicle.sequence_timewindows.size || 7 }.inject(:+)

      # splits using hierarchical tree method
      if vrp.services.all?{ |service| service[:activity] }
        graph = {}
        unit_symbols = vrp.units.collect{ |unit| unit.id.to_sym } << :duration << :visits

        cumulated_metrics = {}

        unit_symbols.map{ |unit| cumulated_metrics[unit] = 0 }

        max_cut_metrics = {}
        unit_symbols.map{ |unit| max_cut_metrics[unit] = 0 }

        # one node per point
        current_index = 0
        vrp.points.each{ |point|
          unit_quantities = {}
          unit_symbols.each{ |unit| unit_quantities[unit] = 0 }
          related_services = vrp.services.select{ |service| service[:activity][:point_id] == point[:id] }
          related_services.each{ |service|
            unit_quantities[:visits] += 1
            cumulated_metrics[:visits] += 1
            unit_quantities[:duration] += service[:activity][:duration] * service[:visits_number]
            cumulated_metrics[:duration] += service[:activity][:duration] * service[:visits_number]

            service.quantities.each{ |quantity|
              unit_quantities[quantity.unit_id.to_sym] += quantity.value * service[:visits_number]
              cumulated_metrics[quantity.unit_id.to_sym] += quantity.value * service[:visits_number]
            }
          }
          unit_symbols.each{ |unit|
            max_cut_metrics[unit] = [unit_quantities[unit], max_cut_metrics[unit]].max
          }

          next if related_services.empty?
          graph[current_index] = {
            points: [point[:id]],
            level: 0,
            parent: nil,
            left: nil,
            right: nil,
            unit_metrics: unit_quantities
          }
          current_index += 1
        }

        metric_limit = cumulated_metrics[cut_symbol] / nb_clusters
        # raise OptimizerWrapper::DiscordantProblemError.new("Unfitting cluster split metric. Maximum value is greater than average") if max_cut_metrics[cut_symbol] > metric_limit
        node_counter = graph.size
        nodes_to_see = graph.keys
        while nodes_to_see.size > 1
          # hierarchical tree logic
          merging_values = {}

          (0..nodes_to_see.size - 2).each{ |n|
            node = nodes_to_see[n]
            (n + 1..nodes_to_see.size - 1).each{ |o|
              other_node = nodes_to_see[o]
              cumulated_distance = 0.0
              graph[node][:points].each{ |first|
                first_point = vrp.points.find{ |point| point[:id] == first }
                graph[other_node][:points].each{ |second|
                  second_point = vrp.points.find{ |point| point[:id] == second }
                  cumulated_distance += custom_distance([first_point[:location][:lat], first_point[:location][:lon]], [second_point[:location][:lat], second_point[:location][:lon]])
                  # cumulated_distance = [cumulated_distance, custom_distance([first_point[:location][:lat], first_point[:location][:lon]], [second_point[:location][:lat], second_point[:location][:lon]])].min
                }
              }
              merging_values[cumulated_distance / (graph[node][:points].size * graph[other_node][:points].size)] = [node, other_node]
              # merging_values[cumulated_distance] = [node, other_node]
            }
          }

          fusion_index = merging_values.keys.min

          # merge nodes
          first_node, second_node = merging_values[fusion_index]
          graph[first_node][:parent] = node_counter
          graph[second_node][:parent] = node_counter
          merged_metrics = {}
          unit_symbols.each{ |symbol|
            merged_metrics[symbol] = graph[first_node][:unit_metrics][symbol] + graph[second_node][:unit_metrics][symbol]
          }
          graph[node_counter] = {
            points: graph[first_node][:points] + graph[second_node][:points],
            level: [graph[first_node][:level], graph[second_node][:level]].max + 1,
            parent: nil,
            left: first_node,
            right: second_node,
            unit_metrics: merged_metrics
          }

          nodes_to_see.delete(first_node)
          nodes_to_see.delete(second_node)
          nodes_to_see << node_counter
          node_counter += 1
        end

        original_graph = Marshal.load(Marshal.dump(graph))

        # Tree cut process
        clusters = []
        max_level = graph.values.collect{ |value| value[:level] }.max

        # Top Down cut
        # current_level = max_level
        # while current_level >= 0
        #   graph.select{ |k, v| v[:level] == current_level }.each{ |k, v|
        #     next if v[:unit_metrics][cut_symbol] > 1.1 * metric_limit && current_level != 0
        #     clusters << tree_leafs_delete(graph, k).flatten.compact
        #   }
        #   current_level -= 1
        # end

        # Bottom Up cut
        (0..max_level).each{ |current_level|
          graph.select{ |k, v| v[:level] == current_level }.each{ |k, v|
            next if v[:unit_metrics][cut_symbol] < metric_limit && current_level != max_level
            clusters << tree_leafs(graph, k).flatten.compact
            next if current_level == max_level
            remove_from_upper(graph, graph[k][:parent], cut_symbol, v[:unit_metrics][cut_symbol])
            if k == graph[v[:parent]][:left]
              graph[v[:parent]][:left] = nil
            else
              graph[v[:parent]][:right] = nil
            end
          }
        }

        # each node corresponds to a cluster
        vehicle_to_use = 0
        vehicle_list = []
        vrp.vehicles.each{ |vehicle|
          if vehicle[:timewindow]
            (0..6).each{ |day|
              tw = Marshal::load(Marshal.dump(vehicle[:timewindow]))
              tw[:day_index] = day
              new_vehicle = Marshal::load(Marshal.dump(vehicle))
              new_vehicle[:timewindow] = tw
              vehicle_list << new_vehicle
            }
          elsif vehicle[:sequence_timewindows]
            vehicle[:sequence_timewindows].each{ |tw|
              new_vehicle = Marshal::load(Marshal.dump(vehicle))
              new_vehicle[:sequence_timewindows] = [tw]
              vehicle_list << new_vehicle
            }
          end
        }
        sub_pbs = []
        points_seen = []
        file = File.new("service_with_tags.csv", "w+")
        file << "name,lat,lng,tags,duration \n"
        clusters.each_with_index{ |cluster, index|
          services_list = []
          cluster.each{ |node|
            point_id = original_graph[node][:points].first
            vrp.services.select{ |serv| serv[:activity][:point_id] == point_id }.each{ |service|
              file << "#{service[:id]},#{service[:activity][:point][:location][:lat]},#{service[:activity][:point][:location][:lon]},#{index},#{service[:activity][:duration] * service[:visits_number]} \n"
              points_seen << service[:id]
              services_list << service[:id]
            }
          }
          vrp_to_send = build_partial_vrp(vrp, services_list)
          vrp_to_send[:vehicles] = [vehicle_list[vehicle_to_use]]
          sub_pbs << {
            service: service_vrp[:service],
            vrp: vrp_to_send,
            fleet_id: service_vrp[:fleet_id],
            problem_size: service_vrp[:problem_size]
          }
          vehicle_to_use += 1
        }
        file.close

        sub_pbs
      else
        puts "split hierarchical not available when services have activities"
        [vrp]
      end
    end
  end
end
