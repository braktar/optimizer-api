require './test/test_helper'
require './test/master_road_helper'

class MasterRoadTest < Minitest::Test
  def test_simple_cut
    problem = VRP.lat_lon_capacitated
    problem[:vehicles] += [{
      id: 'vehicle_1',
      matrix_id: 'm1',
      start_point_id: 'point_0',
      end_point_id: 'point_0',
      router_dimension: 'distance',
      capacities: [{
        unit_id: 'kg',
        limit: 2
      }]
    }, {
      id: 'vehicle_2',
      matrix_id: 'm1',
      start_point_id: 'point_0',
      end_point_id: 'point_0',
      router_dimension: 'distance',
      capacities: [{
        unit_id: 'kg',
        limit: 5
      }]
    }]

    nb_clusters = 2
    sub_problems = Interpreters::SplitClustering.split_road_black_box({ vrp: TestHelper.create(problem) }, nb_clusters, { debug: true, cut_symbol: 'kg' })
    MasterRoadHelper.generate_files(sub_problems, 'simple_cut_2_clusters')
    assert_equal nb_clusters, sub_problems.size
    sub_problems.each{ |sub_problem|
      sub_quantity = sub_problem[:vrp].services.map{ |s| s.quantities.first.value }.sum
      sub_capacity = sub_problem[:vrp].vehicles.map{ |v| v.capacities.first.limit }.sum / nb_clusters
      assert sub_quantity <= sub_capacity, "quantity #{sub_quantity} is expected to be less or equal to the capacity #{sub_capacity}"
    }

    nb_clusters = 3
    sub_problems = Interpreters::SplitClustering.split_road_black_box({ vrp: TestHelper.create(problem) }, nb_clusters, { debug: true, cut_symbol: 'kg' })
    MasterRoadHelper.generate_files(sub_problems, 'simple_cut_3_clusters')
    assert_equal nb_clusters, sub_problems.size
    sub_problems.each{ |sub_problem|
      sub_quantity = sub_problem[:vrp].services.map{ |s| s.quantities.first.value }.sum
      sub_capacity = sub_problem[:vrp].vehicles.first.capacities.first.limit
      assert sub_quantity <= sub_capacity, "quantity #{sub_quantity} is expected to be less or equal to the capacity #{sub_capacity}"
    }
  end

  def test_cluster_one_phase_vehicle
    problem = VRP.lat_lon_scheduling_two_vehicles

    problem[:vehicles].first[:capacities] = [{
      unit_id: 'kg',
      limit: 20
    }]

    problem[:services].size.times{ |i|
      problem[:services][i][:quantities] = [{
        unit_id: 'kg',
        value: i
      }]
    }

    problem[:vehicles][0][:skills] = [['sk1']]
    problem[:vehicles][1][:skills] = [['sk1']]
    problem[:services][0..8].each{ |service|
      service[:skills] = ['sk1']
    }
    nb_clusters = 5
    sub_problems = Interpreters::SplitClustering.split_road_black_box({ vrp: TestHelper.create(problem) }, nb_clusters, { debug: true, cut_symbol: 'kg' })
    MasterRoadHelper.generate_files(sub_problems, 'cluster_one_phase_vehicle_5_clusters')

    assert_equal nb_clusters, sub_problems.size
  end

  def test_basic_split_road
    problem = VRP.lat_lon
    problem[:configuration][:preprocessing] ||= {}
    problem[:configuration][:preprocessing][:partitions] = [{
          method: 'road_black_box',
          metric: 'duration',
          entity: 'vehicle'
        }]
    problem[:vehicles] << {
      id: 'vehicle_1',
      matrix_id: 'm1',
      start_point_id: 'point_0',
      end_point_id: 'point_0',
      router_dimension: 'distance',
    }
    result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, TestHelper.create(problem), nil)
    assert result
  end

  def test_homegeneous_fleet
    vrp = TestHelper.load_vrp(self, fixture_file: 'road_46stops_1depot-4vehicles_60units')
    vrp.preprocessing_partitions = [{
      method: 'road_black_box',
      metric: vrp.units.first.id,
      entity: 'vehicle'
    }]
    result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, vrp, nil)

    assert result
    assert_equal 4, result[:routes].size
    assert_equal 0, result[:unassigned].size
  end

  def test_various_capacities
    vrp = TestHelper.load_vrp(self, fixture_file: 'road_46stops_1depot-4vehicle_various_capacities')
    vrp.preprocessing_partitions = [{
      method: 'road_black_box',
      metric: vrp.units.first.id,
      entity: 'vehicle'
    }]
    result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, vrp, nil)

    assert result
    assert_equal 4, result[:routes].size
    assert_equal 0, result[:unassigned].size
  end

  def test_2vehicles_2depots
    vrp = TestHelper.load_vrp(self, fixture_file: 'road_46stops_2vehicles_120units_2depots')
    vrp.preprocessing_partitions = [{
      method: 'road_black_box',
      metric: vrp.units.first.id,
      entity: 'vehicle'
    }]
    result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, vrp, nil)

    assert result
    assert_equal 2, result[:routes].size
    assert_equal 0, result[:unassigned].size
  end

  def test_4vehicles_2depots
    vrp = TestHelper.load_vrp(self, fixture_file: 'road_46stops_4vehicles_60units_2depots')
    vrp.preprocessing_partitions = [{
      method: 'road_black_box',
      metric: vrp.units.first.id,
      entity: 'vehicle'
    }]
    result = OptimizerWrapper.wrapper_vrp('ortools', { services: { vrp: [:ortools] }}, vrp, nil)

    assert result
    assert_equal 4, result[:routes].size
    assert_equal 0, result[:unassigned].size
  end
end
