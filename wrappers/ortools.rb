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
require './wrappers/wrapper'
require './wrappers/ortools_vrp_pb'
require './wrappers/ortools_result_pb'

require 'open3'
module Wrappers
  class Ortools < Wrapper
    def initialize(hash = {})
      super(hash)
      @exec_ortools = hash[:exec_ortools] || 'LD_LIBRARY_PATH=../or-tools/dependencies/install/lib/:../or-tools/lib/ ../optimizer-ortools/tsp_simple'
      @optimize_time = hash[:optimize_time]
      @resolution_stable_iterations = hash[:optimize_time]
      @previous_result = nil

      @semaphore = Mutex.new
    end

    def solver_constraints
      super + [
        :assert_end_optimization,
        :assert_vehicles_objective,
        :assert_vehicles_no_capacity_initial,
        :assert_vehicles_no_alternative_skills,
        :assert_zones_only_size_one_alternative,
        :assert_only_empty_or_fill_quantities,
        :assert_points_same_definition,
        :assert_vehicles_no_zero_duration,
        :assert_correctness_matrices_vehicles_and_points_definition,
        :assert_square_matrix,
        :assert_vehicle_tw_if_periodic,
        :assert_if_sequence_tw_then_schedule,
        :assert_if_periodic_heuristic_then_schedule,
        :assert_only_force_centroids_if_kmeans_method,
        :assert_no_periodic_if_evaluation,
        :assert_route_if_evaluation,
        :assert_wrong_vehicle_shift_preference_with_heuristic,
        :assert_no_vehicle_overall_duration_if_heuristic,
        :assert_no_vehicle_distance_if_heuristic,
        :assert_possible_to_get_distances_if_maximum_ride_distance,
        :assert_no_vehicle_free_approach_or_return_if_heuristic,
        :assert_no_vehicle_limit_if_heuristic,
        :assert_no_same_point_day_if_no_heuristic,
        :assert_no_allow_partial_if_no_heuristic,
        :assert_solver_if_not_periodic,
        :assert_first_solution_strategy_is_possible,
        :assert_first_solution_strategy_is_valid,
        :assert_clustering_compatible_with_periodic_heuristic,
        :assert_lat_lon_for_partition,
        :assert_vehicle_entity_only_before_work_day,
        :assert_deprecated_partitions,
        :assert_partitions_entity,
        :assert_no_initial_centroids_with_partitions,
        :assert_valid_partitions,
        :assert_route_date_or_indice_if_periodic,
        :assert_not_too_many_visits_in_route,
        :assert_no_route_if_schedule_without_periodic_heuristic,
        # :assert_no_overall_duration, # TODO: Requires a complete rework
      ]
    end

    def solve(vrp, job, thread_proc = nil, &block)
      tic = Time.now
      order_relations = vrp.relations.select{ |relation| relation.type == :order }
      already_begin = order_relations.collect{ |relation| relation.linked_ids[0..-2] }.flatten
      duplicated_begins = already_begin.uniq.select{ |linked_id| already_begin.select{ |link| link == linked_id }.size > 1 }
      already_end = order_relations.collect{ |relation| relation.linked_ids[1..-1] }.flatten
      duplicated_ends = already_end.uniq.select{ |linked_id| already_end.select{ |link| link == linked_id }.size > 1 }
      if vrp.routes.empty? && order_relations.size == 1
        order_relations.select{ |relation| (relation.linked_ids[0..-2] & duplicated_begins).size == 0 && (relation.linked_ids[1..-1] & duplicated_ends).size == 0 }.each{ |relation|
          order_route = {
            vehicle: (vrp.vehicles.size == 1) ? vrp.vehicles.first : nil,
            mission_ids: relation.linked_ids
          }
          vrp.routes += [order_route]
        }
      end

      problem_units = vrp.units.collect{ |unit|
        {
          unit_id: unit.id,
          fill: false,
          empty: false
        }
      }

      vrp.services.each{ |service|
        service.quantities.each{ |quantity|
          unit_status = problem_units.find{ |unit| unit[:unit_id] == quantity.unit_id }
          unit_status[:fill] ||= quantity.fill
          unit_status[:empty] ||= quantity.empty
        }
      }
      # FIXME: or-tools can handle no end-point itself
      @job = job
      @previous_result = nil
      points = Hash[vrp.points.collect{ |point| [point.id, point] }]
      relations = []
      services = []
      services_positions = { always_first: [], always_last: [], never_first: [], never_last: [] }
      vrp.services.each_with_index{ |service, service_index|
        vehicles_indices =
          if service.skills.any? && vrp.vehicles.all?{ |vehicle| vehicle.skills.empty? } &&
             service.unavailable_days.empty?
            []
          else
            vrp.vehicles.collect.with_index{ |vehicle, index|
              if (service.skills.empty? || !vehicle.skills.empty? &&
                 ((vehicle.skills[0] & service.skills).size == service.skills.size) &&
                 check_services_compatible_days(vrp, vehicle, service)) &&
                 (service.unavailable_days.empty? || !service.unavailable_days.include?(vehicle.global_day_index))
                index
              end
            }.compact
          end

        if service.activity
          services << OrtoolsVrp::Service.new(
            time_windows: service.activity.timewindows.collect{ |tw|
              OrtoolsVrp::TimeWindow.new(start: tw.start, end: tw.end || 2**56)
            },
            quantities: vrp.units.collect{ |unit|
              is_empty_unit = problem_units.find{ |unit_status| unit_status[:unit_id] == unit.id }[:empty]
              q = service.quantities.find{ |quantity| quantity.unit == unit }
              q&.value.to_f * (is_empty_unit ? -1 : 1)
            },
            duration: service.activity.duration,
            additional_value: service.activity.additional_value,
            priority: service.priority,
            matrix_index: points[service.activity.point_id].matrix_index,
            vehicle_indices: (service.sticky_vehicles.size > 0 && service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact.size > 0) ?
              service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact : vehicles_indices,
            setup_duration: service.activity.setup_duration,
            id: service.id,
            late_multiplier: service.activity.late_multiplier || 0,
            setup_quantities: vrp.units.collect{ |unit|
              q = service.quantities.find{ |quantity| quantity.unit == unit }
              (q && q.setup_value && unit.counting) ? q.setup_value.to_i : 0
            },
            exclusion_cost: service.exclusion_cost && service.exclusion_cost.to_i || -1,
            refill_quantities: vrp.units.collect{ |unit|
              q = service.quantities.find{ |quantity| quantity.unit == unit }
              !q.nil? && (q.fill || q.empty)
            },
            problem_index: service_index,
          )

          services = update_services_positions(services, services_positions, service.id, service.activity.position, service_index)
        elsif service.activities
          service.activities.each_with_index{ |possible_activity, activity_index|
            services << OrtoolsVrp::Service.new(
              time_windows: possible_activity.timewindows.collect{ |tw|
                OrtoolsVrp::TimeWindow.new(start: tw.start, end: tw.end || 2**56)
              },
              quantities: vrp.units.collect{ |unit|
                is_empty_unit = problem_units.find{ |unit_status| unit_status[:unit_id] == unit.id }[:empty]
                q = service.quantities.find{ |quantity| quantity.unit == unit }
                q&.value.to_f * (is_empty_unit ? -1 : 1)
              },
              duration: possible_activity.duration,
              additional_value: possible_activity.additional_value,
              priority: service.priority,
              matrix_index: points[possible_activity.point_id].matrix_index,
              vehicle_indices: (service.sticky_vehicles.size > 0 && service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact.size > 0) ?
                service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact : vehicles_indices,
              setup_duration: possible_activity.setup_duration,
              id: "#{service.id}_activity#{activity_index}",
              late_multiplier: possible_activity.late_multiplier || 0,
              setup_quantities: vrp.units.collect{ |unit|
                q = service.quantities.find{ |quantity| quantity.unit == unit }
                (q&.setup_value && unit.counting) ? q.setup_value.to_i : 0
              },
              exclusion_cost: service.exclusion_cost || -1,
              refill_quantities: vrp.units.collect{ |unit|
                q = service.quantities.find{ |quantity| quantity.unit == unit }
                !q.nil? && (q.fill || q.empty)
              },
              problem_index: service_index,
            )

            services = update_services_positions(services, services_positions, service.id, possible_activity.position, service_index)
          }
        end
      }
      matrix_indices = vrp.services.collect{ |service|
        service.activity ? points[service.activity.point_id].matrix_index : service.activities.collect{ |activity| points[activity.point_id].matrix_index }
      }

      matrices = vrp.matrices.collect{ |matrix|
        OrtoolsVrp::Matrix.new(
          time: matrix[:time] ? matrix[:time].flatten : [],
          distance: matrix[:distance] ? matrix[:distance].flatten : [],
          value: matrix[:value] ? matrix[:value].flatten : []
        )
      }

      v_types = []
      vrp.vehicles.each{ |vehicle|
        v_type_id = [
          vehicle.cost_fixed,
          vehicle.cost_distance_multiplier,
          vehicle.cost_time_multiplier,
          vehicle.cost_waiting_time_multiplier || vehicle.cost_time_multiplier,
          vehicle.cost_value_multiplier || 0,
          vehicle.cost_late_multiplier || 0,
          vehicle.coef_service || 1,
          vehicle.coef_setup || 1,
          vehicle.additional_service || 0,
          vehicle.additional_setup || 0,
          vrp.units.flat_map{ |unit|
            q = vehicle.capacities.find{ |capacity| capacity.unit == unit }
            [
              (q&.limit && q.limit < 1e+22) ? q.limit : -1,
              q&.overload_multiplier || 0,
              unit&.counting || false
            ]
          }.compact,
          [
            vehicle.timewindow&.start || 0,
            vehicle.timewindow&.end || 2147483647,
          ],
          vehicle.rests.collect{ |rest|
            [
              rest.timewindows.collect{ |tw|
                [
                  tw.start,
                  tw.end || 2**56,
                ]
              },
              rest.duration,
            ].flatten.compact
          },
          vehicle.skills,
          vehicle.matrix_id,
          vehicle.value_matrix_id,
          vehicle.start_point ? points[vehicle.start_point_id].matrix_index : -1,
          vehicle.end_point ? points[vehicle.end_point_id].matrix_index : -1,
          vehicle.duration || -1,
          vehicle.distance || -1,
          (vehicle.force_start ? 'force_start' : vehicle.shift_preference.to_s),
          vehicle.global_day_index || -1,
          vehicle.maximum_ride_time || 0,
          vehicle.maximum_ride_distance || 0,
          vehicle.free_approach || false,
          vehicle.free_return || false
        ].flatten

        v_type_checksum = Digest::MD5.hexdigest(Marshal.dump(v_type_id))
        v_type_index = v_types.index(v_type_checksum)
        if v_type_index
          vehicle.type_index = v_type_index
        else
          vehicle.type_index = v_types.size
          v_types << v_type_checksum
        end
      }
      vehicles = vrp.vehicles.collect{ |vehicle|
        OrtoolsVrp::Vehicle.new(
          id: vehicle.id,
          cost_fixed: vehicle.cost_fixed,
          cost_distance_multiplier: vehicle.cost_distance_multiplier,
          cost_time_multiplier: vehicle.cost_time_multiplier,
          cost_waiting_time_multiplier: vehicle.cost_waiting_time_multiplier || vehicle.cost_time_multiplier,
          cost_value_multiplier: vehicle.cost_value_multiplier || 0,
          cost_late_multiplier: vehicle.cost_late_multiplier || 0,
          coef_service: vehicle.coef_service || 1,
          coef_setup: vehicle.coef_setup || 1,
          additional_service: vehicle.additional_service || 0,
          additional_setup: vehicle.additional_setup || 0,
          capacities: vrp.units.collect{ |unit|
            q = vehicle.capacities.find{ |capacity| capacity.unit == unit }
            OrtoolsVrp::Capacity.new(
              limit: (q&.limit && q.limit < 1e+22) ? q.limit : -1,
              overload_multiplier: q&.overload_multiplier || 0,
              counting: unit&.counting || false
            )
          },
          time_window: OrtoolsVrp::TimeWindow.new(
            start: vehicle.timewindow&.start || 0,
            end: vehicle.timewindow&.end || 2147483647,
          ),
          rests: vehicle.rests.collect{ |rest|
            OrtoolsVrp::Rest.new(
              time_windows: rest.timewindows.collect{ |tw|
                OrtoolsVrp::TimeWindow.new(start: tw.start, end: tw.end || 2**56)
              },
              duration: rest.duration,
              id: rest.id,
              late_multiplier: rest.late_multiplier,
              exclusion_cost: rest.exclusion_cost || -1
            )
          },
          matrix_index: vrp.matrices.index{ |matrix| matrix.id == vehicle.matrix_id },
          value_matrix_index: vrp.matrices.index{ |matrix| matrix.id == vehicle.value_matrix_id } || 0,
          start_index: vehicle.start_point ? points[vehicle.start_point_id].matrix_index : -1,
          end_index: vehicle.end_point ? points[vehicle.end_point_id].matrix_index : -1,
          duration: vehicle.duration || -1,
          distance: vehicle.distance || -1,
          shift_preference: (vehicle.force_start ? 'force_start' : vehicle.shift_preference.to_s),
          day_index: vehicle.global_day_index || -1,
          max_ride_time: vehicle.maximum_ride_time || 0,
          max_ride_distance: vehicle.maximum_ride_distance || 0,
          free_approach: vehicle.free_approach || false,
          free_return: vehicle.free_return || false,
          type_index: vehicle.type_index
        )
      }

      relations += vrp.relations.collect{ |relation|
        current_linked_ids = relation.linked_ids.select{ |mission_id|
          services.one?{ |service| service.id == mission_id }
        }.uniq
        current_linked_vehicles = relation.linked_vehicle_ids.select{ |vehicle_id|
          vrp.vehicles.one? { |vehicle| vehicle.id == vehicle_id }
        }.uniq
        next if current_linked_ids.empty? && current_linked_vehicles.empty?

        OrtoolsVrp::Relation.new(
          type: relation.type,
          linked_ids: current_linked_ids,
          linked_vehicle_ids: current_linked_vehicles,
          lapse: relation.lapse
        )
      }.compact

      routes = vrp.routes.collect{ |route|
        next if route.vehicle.nil? || route.mission_ids.empty?

        service_ids = corresponding_mission_ids(services.collect(&:id), route.mission_ids)
        next if service_ids.empty?

        OrtoolsVrp::Route.new(
          vehicle_id: route.vehicle.id,
          service_ids: service_ids
        )
      }

      relations << OrtoolsVrp::Relation.new(type: :force_first, linked_ids: services_positions[:always_first], lapse: -1) unless services_positions[:always_first].empty?
      relations << OrtoolsVrp::Relation.new(type: :never_first, linked_ids: services_positions[:never_first], lapse: -1) unless services_positions[:never_first].empty?
      relations << OrtoolsVrp::Relation.new(type: :never_last, linked_ids: services_positions[:never_last], lapse: -1) unless services_positions[:never_last].empty?
      relations << OrtoolsVrp::Relation.new(type: :force_end, linked_ids: services_positions[:always_last], lapse: -1) unless services_positions[:always_last].empty?

      problem = OrtoolsVrp::Problem.new(
        vehicles: vehicles,
        services: services,
        matrices: matrices,
        relations: relations,
        routes: routes
      )

      log "ortools solve problem creation elapsed: #{Time.now - tic}sec", level: :debug
      ret = run_ortools(problem, vrp, services, points, matrix_indices, thread_proc, &block)
      case ret
      when String
        return ret
      when Array
        cost, iterations, result = ret
      else
        return ret
      end

      result
    end

    def kill
      @killed = true
    end

    private

    def build_cost_details(cost_details)
      Models::Solution::CostInfo.create(
        fixed: cost_details&.fixed || 0,
        time: cost_details && (cost_details.time + cost_details.time_fake + cost_details.time_without_wait) || 0,
        distance: cost_details && (cost_details.distance + cost_details.distance_fake) || 0,
        value: cost_details&.value || 0,
        lateness: cost_details&.lateness || 0,
        overload: cost_details&.overload || 0
      )
    end

    def build_route_step(vrp, vehicle, activity)
      times = { begin_time: activity.start_time, current_distance: activity.current_distance }
      loads = activity.quantities.map.with_index{ |quantity, index|
        Models::Solution::Load.new(quantity: Models::Quantity.new(unit: vrp.units[index]), current: quantity)
      }
      case activity.type
      when 'start'
        Models::Solution::Step.new(vehicle.start_point, info: times, loads: loads) if vehicle.start_point
      when 'end'
        Models::Solution::Step.new(vehicle.end_point, info: times, loads: loads) if vehicle.end_point
      when 'service'
        service = vrp.services[activity.index]
        @problem_services.delete(service.id)
        Models::Solution::Step.new(service, info: times, loads: loads, index: activity.alternative)
      when 'break'
        vehicle_rest = @problem_rests[vehicle.id][activity.id]
        @problem_rests[vehicle.id].delete(activity.id)
        Models::Solution::Step.new(vehicle_rest, info: times, loads: loads)
      end
    end

    def build_routes(vrp, routes)
      @vehicle_rest_ids = Hash.new([])
      routes.map.with_index{ |route, index|
        vehicle = vrp.vehicles[index]
        route_costs = build_cost_details(route.cost_details)
        steps = route.activities.map{ |activity|
          build_route_step(vrp, vehicle, activity)
        }.compact
        route_detail = Models::Solution::Route::Info.new({})
        initial_loads = route.activities.first.quantities.map.with_index{ |quantity, q_index|
          Models::Solution::Load.new(quantity: Models::Quantity.new(unit: vrp.units[q_index]), current: quantity)
        }
        Models::Solution::Route.new(
          steps: steps,
          initial_loads: initial_loads,
          cost_info: route_costs,
          info: route_detail,
          vehicle: vehicle
        )
      }
    end

    def build_unassigned
      @problem_services.values.map{ |service| Models::Solution::Step.new(service) } +
        @problem_rests.flat_map{ |_v_id, v_rests| v_rests.values.map{ |v_rest| Models::Solution::Step.new(v_rest) } }
    end

    def build_solution(vrp, content)
      @problem_services = vrp.services.map{ |service| [service.id, service] }.to_h
      @problem_rests = vrp.vehicles.map{ |vehicle|
        [vehicle.id, vehicle.rests.map{ |rest| [rest.id, rest] }.to_h]
      }.to_h
      routes = build_routes(vrp, content.routes)
      cost_info = routes.map(&:cost_info).sum
      Models::Solution.new(
        cost: content.cost,
        cost_info: cost_info,
        solvers: [:ortools],
        iterations: content.iterations,
        elapsed: content.duration * 1000,
        routes: routes,
        unassigned: build_unassigned
      )
    end

    def check_services_compatible_days(vrp, vehicle, service)
      !vrp.schedule? || (!service.minimum_lapse && !service.maximum_lapse) ||
        vehicle.global_day_index.between?(service.first_possible_days.first, service.last_possible_days.first)
    end

    def build_route_data(vehicle_matrix, previous_matrix_index, current_matrix_index)
      if previous_matrix_index && current_matrix_index
        travel_distance = vehicle_matrix[:distance] ? vehicle_matrix[:distance][previous_matrix_index][current_matrix_index] : 0
        travel_time = vehicle_matrix[:time] ? vehicle_matrix[:time][previous_matrix_index][current_matrix_index] : 0
        travel_value = vehicle_matrix[:value] ? vehicle_matrix[:value][previous_matrix_index][current_matrix_index] : 0
        return {
          travel_distance: travel_distance,
          travel_time: travel_time,
          travel_value: travel_value
        }
      end
      {}
    end

    def parse_output(vrp, _services, points, _matrix_indices, _cost, _iterations, output)
      if vrp.vehicles.empty? || vrp.services.empty?
        return vrp.empty_solution(:ortools)
      end

      output.rewind
      content = OrtoolsResult::Result.decode(output.read)
      output.rewind

      return @previous_result if content.routes.empty? && @previous_result

      solution = build_solution(vrp, content)

      solution.parse_solution(vrp)
    end

    def run_ortools(problem, vrp, services, points, matrix_indices, thread_proc = nil, &block)
      log "----> run_ortools services(#{services.size}) preassigned(#{vrp.routes.flat_map{ |r| r[:mission_ids].size }.sum}) vehicles(#{vrp.vehicles.size})"
      tic = Time.now
      if vrp.vehicles.empty? || vrp.services.empty?
        return [0, 0, @previous_result = parse_output(vrp, services, points, matrix_indices, 0, 0, nil)]
      end

      input = Tempfile.new('optimize-or-tools-input', @tmp_dir, binmode: true)
      input.write(OrtoolsVrp::Problem.encode(problem))
      input.close

      output = Tempfile.new('optimize-or-tools-output', @tmp_dir, binmode: true)

      correspondant = { 'path_cheapest_arc' => 0, 'global_cheapest_arc' => 1, 'local_cheapest_insertion' => 2, 'savings' => 3, 'parallel_cheapest_insertion' => 4, 'first_unbound' => 5, 'christofides' => 6 }

      raise StandardError, "Inconsistent first solution strategy used internally: #{vrp.preprocessing_first_solution_strategy}" if vrp.preprocessing_first_solution_strategy.any? && correspondant[vrp.preprocessing_first_solution_strategy.first].nil?

      cmd = [
              "#{@exec_ortools} ",
              (vrp.resolution_duration || @optimize_time) && '-time_limit_in_ms ' + (vrp.resolution_duration || @optimize_time).round.to_s,
              vrp.preprocessing_prefer_short_segment ? '-nearby' : nil,
              (vrp.resolution_evaluate_only ? nil : (vrp.preprocessing_neighbourhood_size ? "-neighbourhood #{vrp.preprocessing_neighbourhood_size}" : nil)),
              (vrp.resolution_iterations_without_improvment || @iterations_without_improvment) && '-no_solution_improvement_limit ' + (vrp.resolution_iterations_without_improvment || @iterations_without_improvment).to_s,
              (vrp.resolution_minimum_duration || vrp.resolution_initial_time_out) && '-minimum_duration ' + (vrp.resolution_minimum_duration || vrp.resolution_initial_time_out).round.to_s,
              (vrp.resolution_time_out_multiplier || @time_out_multiplier) && '-time_out_multiplier ' + (vrp.resolution_time_out_multiplier || @time_out_multiplier).to_s,
              vrp.resolution_init_duration ? "-init_duration #{vrp.resolution_init_duration.round}" : nil,
              (vrp.resolution_vehicle_limit && vrp.resolution_vehicle_limit < problem.vehicles.size) ? "-vehicle_limit #{vrp.resolution_vehicle_limit}" : nil,
              vrp.preprocessing_first_solution_strategy.any? ? "-solver_parameter #{correspondant[vrp.preprocessing_first_solution_strategy.first]}" : nil,
              (vrp.resolution_evaluate_only || vrp.resolution_batch_heuristic) ? '-only_first_solution' : nil,
              vrp.restitution_intermediate_solutions ? '-intermediate_solutions' : nil,
              "-instance_file '#{input.path}'",
              "-solution_file '#{output.path}'"
            ].compact.join(' ')

      log cmd

      stdin, stdout_and_stderr, @thread = @semaphore.synchronize {
        Open3.popen2e(cmd) if !@killed
      }

      return if !@thread

      pipe = @semaphore.synchronize {
        IO.popen("ps -ef | grep #{@thread.pid}")
      }

      childs = pipe.readlines.map do |line|
        parts = line.split(/\s+/)
        parts[1].to_i if parts[2] == @thread.pid.to_s
      end.compact || []
      childs << @thread.pid

      thread_proc&.call(childs)

      out = ''
      iterations = 0
      cost = nil
      time = 0.0
      # read of stdout_and_stderr stops at the end of process
      stdout_and_stderr.each_line { |line|
        r = /Iteration : ([0-9]+)/.match(line)
        r && (iterations = Integer(r[1]))
        s = / Cost : ([0-9.eE+]+)/.match(line)
        s && (cost = Float(s[1]))
        t = /Time : ([0-9.eE+]+)/.match(line)
        t && (time = t[1].to_f)
        log line.strip, level: (/Final Iteration :/.match(line) || /First solution strategy :/.match(line) || /Using the provided initial solution./.match(line) || /OR-Tools v[0-9]+\.[0-9]+\n/.match(line)) ? :info : (r || s || t) ? :debug : :error
        out += line

        next unless r && t # if there is no iteration and time then there is nothing to do

        begin
          @previous_result = if vrp.restitution_intermediate_solutions && s && !/Final Iteration :/.match(line)
                               parse_output(vrp, services, points, matrix_indices, cost, iterations, output)
                             end
          block&.call(self, iterations, nil, nil, cost, time, @previous_result) # if @previous_result=nil, it will not override the existing solution
        rescue Google::Protobuf::ParseError => e
          # log and ignore protobuf parsing errors
          log "#{e.class}: #{e.message} (in run_ortools during parse_output)", level: :error
        end
      }

      result = out.split("\n")[-1]
      if @thread.value.success?
        if result == 'No solution found...'
          cost = Helper.fixnum_max
          @previous_result = vrp.empty_solution(:ortools)
          @previous_result[:cost] = cost
        else
          @previous_result = parse_output(vrp, services, points, matrix_indices, cost, iterations, output)
        end
        [cost, iterations, @previous_result]
      elsif @thread.value.signaled? && @thread.value.termsig == 9
        raise OptimizerWrapper::JobKilledError
      else # Fatal Error
        message = case @thread.value
                  when 127
                    'Executable does not exist'
                  when 137 # Segmentation Fault
                    "SIGKILL received: manual intervention or 'oom-killer' [OUT-OF-MEMORY]"
                  else
                    "Job terminated with unknown thread status: #{@thread.value}"
                  end
        raise message
      end
    ensure
      input&.unlink
      output&.close
      output&.unlink
      @thread&.value # wait for the termination of the thread in case there is one
      stdin&.close
      stdout_and_stderr&.close
      pipe&.close
      log "<---- run_ortools #{Time.now - tic}sec elapsed", level: :debug
    end

    def update_services_positions(services, services_positions, id, position, service_index)
      services_positions[:always_first] << id if position == :always_first
      services_positions[:never_first] << id if [:never_first, :always_middle].include?(position)
      services_positions[:never_last] << id if [:never_last, :always_middle].include?(position)
      services_positions[:always_last] << id if position == :always_last

      return services if position != :never_middle

      services + services.select{ |s| s.problem_index == service_index }.collect{ |s|
        services_positions[:always_first] << id
        services_positions[:always_last] << "#{id}_alternative"
        copy_s = s.dup
        copy_s.id += '_alternative'
        copy_s
      }
    end

    def corresponding_mission_ids(available_ids, mission_ids)
      mission_ids.collect{ |mission_id|
        correct_id = if available_ids.include?(mission_id)
          mission_id
        elsif available_ids.include?("#{mission_id}pickup")
          "#{mission_id}pickup"
        elsif available_ids.include?("#{mission_id}delivery")
          "#{mission_id}delivery"
        end

        available_ids.delete(correct_id)
        correct_id
      }.compact
    end
  end
end
