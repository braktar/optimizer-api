require './test/test_helper'

class MasterRoadHelper
  def self.generate_files(problems, file_name)
    file_name = ("generated_clusters-#{file_name}").parameterize

    polygons = []
    points = []
    problems.each_with_index{ |service_vrp, cluster_index|
      polygons << collect_hulls(service_vrp) # unless service_vrp[:vrp].services.empty? -----> possible to get here if cluster empty ??
      points += collect_points(service_vrp)
    }

    Api::V01::APIBase.dump_vrp_dir.write(file_name + '_geojson', {
      type: 'FeatureCollection',
      features: polygons.compact + points.compact
    }.to_json)

    log 'Clusters saved: ' + file_name, level: :debug
    file_name
  end

  def self.collect_hulls(service_vrp)
    vector = service_vrp[:vrp].services.collect{ |service|
      [service.activity.point.location.lon, service.activity.point.location.lat]
    }
    hull = Hull.get_hull(vector)
    return nil if hull.nil?

    unit_objects = service_vrp[:vrp].units.collect{ |unit|
      {
        unit_id: unit.id,
        value: service_vrp[:vrp].services.collect{ |service|
          service_quantity = service.quantities.find{ |quantity| quantity.unit_id == unit.id }
          service_quantity&.value || 0
        }.reduce(&:+)
      }
    }
    duration = service_vrp[:vrp][:services].group_by{ |s| s.activity.point_id }.map{ |_point_id, ss|
      first = ss.min_by{ |s| -s.visits_number }
      duration = first.activity.setup_duration * first.visits_number + ss.map{ |s| s.activity.duration * s.visits_number }.sum
    }.sum
    {
      type: 'Feature',
      properties: Hash[unit_objects.collect{ |unit_object| [unit_object[:unit_id].to_sym, unit_object[:value]] } + [[:duration, duration]] + [[:vehicle, (service_vrp[:vrp].vehicles.size == 1) ? service_vrp[:vrp].vehicles.first&.id : nil]]],
      geometry: {
        type: 'Polygon',
        coordinates: [hull + [hull.first]]
      }
    }
  end

  def self.collect_points(service_vrp)
    service_vrp[:vrp].services.map{ |service|
      {
        type: 'Feature',
        properties: service.quantities.map{ |quantity|
          [quantity.unit.id, quantity.value]
        }.to_h,
        geometry: {
          type: 'Point',
          coordinates: [service.activity.point.location.lon, service.activity.point.location.lat]
        }
      }
    }
  end

  def build_geojson(problem, file_name)
    assignment = problem.solution.assignment
    cluster_indices = assignment.uniq.size
    cluster_size = assignment.max
    node_assignements = Array.new(cluster_size)

    assignment.each.with_index{ |cluster, node_index|
      node_assignements[cluster] << node_assignements
    }

    node_assignements.each.with_index{ |cluster_data, cluster_index|
      cluster_data.map{ |node_index|
        service = problem.services[node_index]
        [service.location.lat, service.location.lon]
      }
    }
  end
end
