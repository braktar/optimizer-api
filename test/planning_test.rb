# Copyright © Mapotempo, 2018

# This file is part of Mapotempo.

# Mapotempo is free software. You can redistribute it and/or
# modify since you respect the terms of the GNU Affero General
# Public License as published by the Free Software Foundation,
# either version 3 of the License, or (at your option) any later version.

# Mapotempo is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the Licenses for more details.

# You should have received a copy of the GNU Affero General Public License
# along with Mapotempo. If not, see:
# <http://www.gnu.org/licenses/agpl.html>

require './test/test_helper'
require 'byebug'

class PlanningTest < Minitest::Test

  def output_final_sol(vrp, result)
    d = DateTime.now
    output = File.open( "/home/adeline/Documents/PlanningOptimization/resultats/#{d.day}_#{d.month}_#{d.hour}_#{d.min}_#{d.sec}_resultat_ortools.csv","a" )
    output << "name,visit duration,tags,route,lat,lng \n"
    result[:routes].each{ |route|
      vehicle = route[:vehicle_id]
      day = vehicle.split("_").last
      start_point = vrp[:vehicles].find{ |v| v[:id] == vehicle }[:start_point_id]
      end_point = vrp[:vehicles].find{ |v| v[:id] == vehicle }[:end_point_id]
      route[:activities].each{ |stop|
        if stop[:point_id] != start_point && stop[:point_id] != end_point
          service_in_vrp = vrp[:services].find{ |s| s[:id] == stop[:service_id] }
          hour = (service_in_vrp[:activity][:duration]/3600).floor
          hour = (hour < 10 ? "0#{hour}" : "#{hour}")
          min = ((service_in_vrp[:activity][:duration]-3600*hour.to_i)/60).floor
          min = (min < 10 ? "0#{min}" : "#{min}")
          secs = (service_in_vrp[:activity][:duration]-3600*hour.to_i-60*min.to_i).to_i
          secs = (secs < 10 ? "0#{secs}" : "#{secs}")
          if service_in_vrp[:activity][:point][:location].nil?
            output << "#{stop[:service_id]},#{hour}:#{min}:#{secs},#{service_in_vrp[:visits_number]},#{day},,,#{service_in_vrp[:activity][:point][:matrix_index]} \n"
          else
            output << "#{stop[:service_id]},#{hour}:#{min}:#{secs},#{service_in_vrp[:visits_number]},#{day},#{service_in_vrp[:activity][:point][:location][:lat]},#{service_in_vrp[:activity][:point][:location][:lon]} \n"
          end
        end
      }
    }

    result[:unassigned].each{ |stop|
      service_in_vrp = vrp[:services].find{ |service| service[:id] == stop[:service_id] }
      hour = (service_in_vrp[:activity][:duration]/3600).floor
      hour = (hour < 10 ? "0#{hour}" : "#{hour}")
      min = ((service_in_vrp[:activity][:duration]-3600*hour.to_i)/60).floor
      min = (min < 10 ? "0#{min}" : "#{min}")
      secs = (service_in_vrp[:activity][:duration]-3600*hour.to_i-60*min.to_i).to_i
      secs = (secs < 10 ? "0#{secs}" : "#{secs}")
      if service_in_vrp[:activity][:point][:location].nil?
        output << "#{stop[:service_id]},#{hour}:#{min}:#{secs},#{service_in_vrp[:visits_number]},,,,#{service_in_vrp[:activity][:point][:matrix_index]} \n"
      else
        output << "#{stop[:service_id]},#{hour}:#{min}:#{secs},#{service_in_vrp[:visits_number]},,#{service_in_vrp[:activity][:point][:location][:lat]},#{service_in_vrp[:activity][:point][:location][:lon]} \n"
      end
    }

    output.close
  end

  def test_baleares2
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_baleares2.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 0, result[:unassigned].size
  end

  def test_madrid_nord2
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_madrid_nord2.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 0, result[:unassigned].size
  end

  def test_barcelona_sur
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_barcelona_sur.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 0, result[:unassigned].size
  end

  def test_andalucia1
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_andalucia1.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 64, result[:unassigned].size
  end

  def test_andalucia2
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_andalucia2.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 13, result[:unassigned].size
  end

  def test_iberia
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_iberia.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 27, result[:unassigned].size
  end

  def test_iberia_norte
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_iberia_norte.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 21, result[:unassigned].size
  end

  # using several vehicles :
  def test_andalucia1_two_vehicles
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_andalucia1_two_vehicles.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 1, result[:unassigned].size
    # for now solution is not accepted by ortools because 2/2 not inserted for 1916
  end

  def test_beziers
    vrp = Models::Vrp.create(Hashie.symbolize_keys(JSON.parse(File.open('test/planning_optimization/instance_Beziers_2.json').to_a.join)['vrp']))
    result = OptimizerWrapper.wrapper_vrp('ortools', {services: {vrp: [:ortools]}}, vrp, nil)
    assert result
    assert_equal 5, result[:unassigned].size
    # for now solution is not accepted by ortools
  end
end
