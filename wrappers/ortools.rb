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
require 'thread'

module Wrappers
  class Ortools < Wrapper
    def initialize(cache, hash = {})
      super(cache, hash)
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
        :assert_vehicles_at_least_one,
        :assert_vehicles_no_capacity_initial,
        :assert_vehicles_no_alternative_skills,
        :assert_zones_only_size_one_alternative,
        :assert_only_empty_or_fill_quantities,
        :assert_points_same_definition,
        :assert_vehicles_no_zero_duration,
        :assert_at_least_one_mission,
        :assert_range_date_if_month_duration,
        :assert_correctness_provided_matrix_indices,
        :assert_square_matrix,
        :assert_vehicle_tw_if_schedule,
        :assert_if_sequence_tw_then_schedule,
        :assert_if_periodic_heuristic_then_schedule,
        :assert_only_force_centroids_if_kmeans_method,
        :assert_no_scheduling_if_evaluation,
        :assert_route_if_evaluation,
        :assert_no_shipments_if_evaluation,
        :assert_wrong_vehicle_shift_preference_with_heuristic,
        :assert_no_vehicle_overall_duration_if_heuristic,
        :assert_no_vehicle_distance_if_heuristic,
        :assert_possible_to_get_distances_if_maximum_ride_distance,
        :assert_no_skills_if_heuristic,
        :assert_no_vehicle_free_approach_or_return_if_heuristic,
        :assert_no_service_exclusion_cost_if_heuristic,
        :assert_no_vehicle_limit_if_heuristic,
        :assert_no_same_point_day_if_no_heuristic,
        :assert_no_allow_partial_if_no_heuristic,
        :assert_solver_if_not_periodic,
        :assert_first_solution_strategy_is_possible,
        :assert_first_solution_strategy_is_valid,
        :assert_clustering_compatible_with_scheduling_heuristic,
        :assert_lat_lon_for_partition,
        :assert_work_day_partitions_only_schedule,
        :assert_deprecated_partitions,
        :assert_partitions_entity,
        :assert_no_initial_centroids_with_partitions,
        :assert_valid_partitions,
        :assert_no_relation_with_scheduling_heuristic,
        :assert_only_one_activity_with_scheduling_heuristic,
      ]
    end

    def solve(vrp, job, thread_proc = nil, &block)
      order_relations = vrp.relations.select{ |relation| relation.type == 'order' }
      already_begin = order_relations.collect{ |relation| relation.linked_ids[0..-2] }.flatten
      duplicated_begins = already_begin.uniq.select{ |linked_id| already_begin.select{ |link| link == linked_id }.size > 1 }
      already_end = order_relations.collect{ |relation| relation.linked_ids[1..-1] }.flatten
      duplicated_ends = already_end.uniq.select{ |linked_id| already_end.select{ |link| link == linked_id }.size > 1 }
      order_relations.select{ |relation| (relation.linked_ids[0..-2] & duplicated_begins).size == 0 && (relation.linked_ids[1..-1] & duplicated_ends).size == 0 }.each{ |relation|
        order_route = {
          id: 'automatic_route_order' + (vrp.vehicles.size == 1 ? vrp.vehicles.first.id : vrp.relations.find{ |relation| relation.type == 'order' }[:id]),
          vehicle: vrp.vehicles.size == 1 ? vrp.vehicles.first : nil,
          mission_ids: relation.linked_ids
        }
        vrp.routes += [order_route]
      } if vrp.routes.empty? && order_relations.size == 1

      vrp.vehicles.sort!{ |a, b|
        a.global_day_index && b.global_day_index && a.global_day_index != b.global_day_index ? a.global_day_index <=> b.global_day_index : a.id <=> b.id
      }

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
# FIXME or-tools can handle no end-point itself
      @job = job
      @previous_result = nil
      points = Hash[vrp.points.collect{ |point| [point.id, point] }]
      relations = []
      services = []
      vrp.services.each_with_index{ |service, service_index|
        vehicles_indices = if !service[:skills].empty? && (vrp.vehicles.all? { |vehicle| vehicle.skills.empty? }) && service[:unavailable_visit_day_indices].empty?
          []
        else
          vrp.vehicles.collect.with_index{ |vehicle, index|
            if (service.skills.empty? || !vehicle.skills.empty? && ((vehicle.skills[0] & service.skills).size == service.skills.size) &&
            check_services_compatible_days(vrp, vehicle, service)) && (service.unavailable_visit_day_indices.empty? || !service.unavailable_visit_day_indices.include?(vehicle.global_day_index))
              index
            else
              nil
            end
          }.compact
        end
        if service.activity
          services << OrtoolsVrp::Service.new(
          time_windows: service.activity.timewindows.collect{ |tw| OrtoolsVrp::TimeWindow.new(
            start: tw.start || -2**56,
            end: tw.end || 2**56,
          ) },
          quantities: vrp.units.collect{ |unit|
            is_empty_unit = problem_units.find{ |unit_status| unit_status[:unit_id] == unit.id }[:empty]
            q = service.quantities.find{ |quantity| quantity.unit == unit }
            q && q.value ? (is_empty_unit ? -1 : 1) * (service.type.to_s == "delivery" ? -1 : 1) * (q.value*(unit.counting ? 1 : 1000)+0.5).to_i : 0
          },
          duration: service.activity.duration,
          additional_value: service.activity.additional_value,
          priority: service.priority,
          matrix_index: points[service.activity.point_id].matrix_index,
          vehicle_indices: service.sticky_vehicles.size > 0 && service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact.size > 0 ?
            service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact : vehicles_indices,
          setup_duration: service.activity.setup_duration,
          id: service.id,
          late_multiplier: service.activity.late_multiplier || 0,
          setup_quantities: vrp.units.collect{ |unit|
            q = service.quantities.find{ |quantity| quantity.unit == unit }
            q && q.setup_value && unit.counting ? (q.setup_value).to_i : 0
          },
          exclusion_cost: service.exclusion_cost && service.exclusion_cost.to_i || -1,
          refill_quantities: vrp.units.collect{ |unit|
            q = service.quantities.find{ |quantity| quantity.unit == unit }
            !q.nil? && (q.fill || q.empty)
          },
          problem_index: service_index,
        )
        elsif
          service.activities.each{ |possible_activity|
            services << OrtoolsVrp::Service.new(
              time_windows: possible_activity.timewindows.collect{ |tw| OrtoolsVrp::TimeWindow.new(
                start: tw.start || -2**56,
                end: tw.end || 2**56,
              ) },
              quantities: vrp.units.collect{ |unit|
                is_empty_unit = problem_units.find{ |unit_status| unit_status[:unit_id] == unit.id }[:empty]
                q = service.quantities.find{ |quantity| quantity.unit == unit }
                q && q.value ? (is_empty_unit ? -1 : 1) * (service.type.to_s == "delivery" ? -1 : 1) * (q.value*(unit.counting ? 1 : 1000)+0.5).to_i : 0
              },
              duration: possible_activity.duration,
              additional_value: possible_activity.additional_value,
              priority: service.priority,
              matrix_index: points[possible_activity.point_id].matrix_index,
              vehicle_indices: service.sticky_vehicles.size > 0 && service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact.size > 0 ?
                service.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) }.compact : vehicles_indices,
              setup_duration: possible_activity.setup_duration,
              id: service.id,
              late_multiplier: possible_activity.late_multiplier || 0,
              setup_quantities: vrp.units.collect{ |unit|
                q = service.quantities.find{ |quantity| quantity.unit == unit }
                q && q.setup_value && unit.counting ? (q.setup_value).to_i : 0
              },
              exclusion_cost: service.exclusion_cost || -1,
              refill_quantities: vrp.units.collect{ |unit|
                q = service.quantities.find{ |quantity| quantity.unit == unit }
                !q.nil? && (q.fill || q.empty)
              },
              problem_index: service_index,
            )
          }
        end
      }
      vrp.shipments.each_with_index{ |shipment, shipment_index|
        vehicles_indices = if !shipment[:skills].empty? && (vrp.vehicles.all? { |vehicle| vehicle.skills.empty? })
          []
        else
          vrp.vehicles.collect.with_index{ |vehicle, index|
            if shipment.skills.empty? || !vehicle.skills.empty? && ((vehicle.skills[0] & shipment.skills).size == shipment.skills.size) &&
            (shipment.unavailable_visit_day_indices.empty? || !shipment.unavailable_visit_day_indices.include(vehicle.global_day_index))
              index
            else
              nil
            end
          }.compact
        end
        relations <<  OrtoolsVrp::Relation.new(
          type: "shipment",
          linked_ids: [shipment.id + "pickup", shipment.id + "delivery"],
          lapse: -1
        )
        if shipment.maximum_inroute_duration && shipment.maximum_inroute_duration > 0
          relations <<  OrtoolsVrp::Relation.new(
            type: "maximum_duration_lapse",
            linked_ids: [shipment.id + "pickup", shipment.id + "delivery"],
            lapse: shipment.maximum_inroute_duration
          )
        end
        services << OrtoolsVrp::Service.new(
          time_windows: shipment.pickup.timewindows.collect{ |tw| OrtoolsVrp::TimeWindow.new(
            start: tw.start || -2**56,
            end: tw.end || 2**56,
          ) },
          quantities: vrp.units.collect{ |unit|
            is_empty_unit = problem_units.find{ |unit_status| unit_status[:unit_id] == unit.id }[:empty]
            q = shipment.quantities.find{ |quantity| quantity.unit == unit }
            q && q.value ? (is_empty_unit ? -1 : 1) * (q.value*1000+0.5).to_i : 0
          },
          duration: shipment.pickup.duration,
          additional_value: shipment.pickup.additional_value,
          priority: shipment.priority,
          matrix_index: points[shipment.pickup.point_id].matrix_index,
          vehicle_indices: shipment.sticky_vehicles.size > 0 ? shipment.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) } : vehicles_indices,
          setup_duration: shipment.pickup.setup_duration,
          id: shipment.id + "pickup",
          late_multiplier: shipment.pickup.late_multiplier || 0,
          exclusion_cost: shipment.exclusion_cost || -1,
          refill_quantities: vrp.units.collect{ |unit| false },
          problem_index: vrp.services.size + 2 * shipment_index,
        )
        services << OrtoolsVrp::Service.new(
          time_windows: shipment.delivery.timewindows.collect{ |tw| OrtoolsVrp::TimeWindow.new(
            start: tw.start || -2**56,
            end: tw.end || 2**56,
          ) },
          quantities: vrp.units.collect{ |unit|
            is_empty_unit = problem_units.find{ |unit_status| unit_status[:unit_id] == unit.id }[:empty]
            q = shipment.quantities.find{ |quantity| quantity.unit == unit }
            q && q.value ? - (is_empty_unit ? -1 : 1) * (q.value*1000+0.5).to_i : 0
          },
          duration: shipment.delivery.duration,
          additional_value: shipment.delivery.additional_value,
          priority: shipment.priority,
          matrix_index: points[shipment.delivery.point_id].matrix_index,
          vehicle_indices: shipment.sticky_vehicles.size > 0 ? shipment.sticky_vehicles.collect{ |sticky_vehicle| vrp.vehicles.index(sticky_vehicle) } : vehicles_indices,
          setup_duration: shipment.delivery.setup_duration,
          id: shipment.id + "delivery",
          late_multiplier: shipment.delivery.late_multiplier || 0,
          exclusion_cost: shipment.exclusion_cost || -1,
          refill_quantities: vrp.units.collect{ |unit| false },
          problem_index: vrp.services.size + 2 * shipment_index + 1,
        )
      }.flatten(1)

      matrix_indices = vrp.services.collect{ |service|
        service.activity ? points[service.activity.point_id].matrix_index : service.activities.collect{ |activity| points[activity.point_id].matrix_index }
      } + vrp.shipments.collect{ |shipment|
        [points[shipment.pickup.point_id].matrix_index, points[shipment.delivery.point_id].matrix_index]
      }.flatten(1)

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
          vrp.units.collect{ |unit|
            q = vehicle.capacities.find{ |capacity| capacity.unit == unit }
            [
              q && q.limit && q.limit < 1e+22 ? unit.counting ? q.limit : (q.limit*1000+0.5).to_i : -2147483648,
              (q && q.overload_multiplier) || 0,
              (unit && unit.counting) || false
            ]
          }.flatten.compact,
          [
            (vehicle.timewindow && vehicle.timewindow.start) || 0,
            (vehicle.timewindow && vehicle.timewindow.end) || 2147483647,
          ],
          vehicle.rests.collect{ |rest|
            [
              rest.timewindows.collect{ |tw|
                [
                  tw.start || -2**56,
                  end: tw.end || 2**56,
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
          vehicle.duration ? vehicle.duration : -1,
          vehicle.distance ? vehicle.distance : -1,
          (vehicle.force_start ? 'force_start' : vehicle.shift_preference.to_s),
          vehicle.global_day_index ? vehicle.global_day_index : -1,
          vehicle.maximum_ride_time || 0,
          vehicle.maximum_ride_distance || 0,
          vehicle.free_approach ? vehicle.free_approach : false,
          vehicle.free_return ? vehicle.free_return : false
        ].flatten

        v_type_checksum = Digest::MD5.hexdigest(Marshal.dump(v_type_id))
        v_type_index = v_types.index(v_type_checksum)
        if v_type_index &&
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
              limit: q && q.limit && q.limit < 1e+22 ? unit.counting ? q.limit : (q.limit*1000+0.5).to_i : -2147483648,
              overload_multiplier: (q && q.overload_multiplier) || 0,
              counting: (unit && unit.counting) || false
            )
          },
          time_window: OrtoolsVrp::TimeWindow.new(
            start: (vehicle.timewindow && vehicle.timewindow.start) || 0,
            end: (vehicle.timewindow && vehicle.timewindow.end) || 2147483647,
          ),
          rests: vehicle.rests.collect{ |rest|
            OrtoolsVrp::Rest.new(
              time_windows: rest.timewindows.collect{ |tw| OrtoolsVrp::TimeWindow.new(
                start: tw.start || -2**56,
                end: tw.end || 2**56,
              ) },
              duration: rest.duration,
              id: rest.id,
              late_multiplier: rest.late_multiplier,
              exclusion_cost: rest.exclusion_cost ? rest.exclusion_cost : -1
            )
          },
          matrix_index: vrp.matrices.index{ |matrix| matrix.id == vehicle.matrix_id },
          value_matrix_index: vrp.matrices.index{ |matrix| matrix.id == vehicle.value_matrix_id } || 0,
          start_index: vehicle.start_point ? points[vehicle.start_point_id].matrix_index : -1,
          end_index: vehicle.end_point ? points[vehicle.end_point_id].matrix_index : -1,
          duration: vehicle.duration ? vehicle.duration : -1,
          distance: vehicle.distance ? vehicle.distance : -1,
          shift_preference: (vehicle.force_start ? 'force_start' : vehicle.shift_preference.to_s),
          day_index: vehicle.global_day_index ? vehicle.global_day_index : -1,
          max_ride_time: vehicle.maximum_ride_time || 0,
          max_ride_distance: vehicle.maximum_ride_distance || 0,
          free_approach: vehicle.free_approach ? vehicle.free_approach : false,
          free_return: vehicle.free_return ? vehicle.free_return : false,
          type_index: vehicle.type_index
        )
      }

      relations += vrp.relations.collect{ |relation|
        current_linked_ids = relation.linked_ids.select{ |mission_id|
          vrp.services.one? { |service| service.id == mission_id } ||
          vrp.shipments.one? { |shipment| "#{shipment.id}pickup" == mission_id } ||
          vrp.shipments.one? { |shipment| "#{shipment.id}delivery" == mission_id }
        }.uniq
        current_linked_vehicles = relation.linked_vehicle_ids.select{ |vehicle_id|
          vrp.vehicles.one? { |vehicle| vehicle.id == vehicle_id }
        }.uniq
        if !current_linked_ids.empty? || !current_linked_vehicles.empty?
          OrtoolsVrp::Relation.new(
            type: relation.type.to_s,
            linked_ids: current_linked_ids,
            linked_vehicle_ids: current_linked_vehicles,
            lapse: relation.lapse || -1
          )
        end
      }.compact
      routes = vrp.routes.collect{ |route|
        if !route.vehicle.nil? && !route.mission_ids.empty?
          OrtoolsVrp::Route.new(
            vehicle_id: route.vehicle.id,
            service_ids: route.mission_ids.select{ |mission_id|
              vrp.services.one? { |service| service.id == mission_id } ||
              vrp.shipments.one? { |shipment| "#{shipment.id}pickup" == mission_id } ||
              vrp.shipments.one? { |shipment| "#{shipment.id}delivery" == mission_id }
            }.uniq
          )
        end
      }

      problem = OrtoolsVrp::Problem.new(
        vehicles: vehicles,
        services: services,
        matrices: matrices,
        relations: relations,
        routes: routes
      )
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

    def closest_rest_start(timewindows, current_start)
      (timewindows.size == 0 || timewindows.one?{ |tw| tw[:start].nil? || current_start >= tw[:start] && (current_start <= tw[:end] || tw[:end].nil?) }) ? current_start :
        (timewindows.sort_by { |tw0, tw1| tw1 ? tw0[:start] < tw1[:start] : tw0 }.find{ |tw| tw[:start] > current_start } || timewindows.first)[:start]
    end

    def kill
      @killed = true
    end

    private

    def build_timewindows(activity, day_index)
      activity.timewindows.select{ |timewindow| timewindow.day_index.nil? || timewindow.day_index == day_index}.collect{ |timewindow|
        {
          start: timewindow.start,
          end: timewindow.end
        }
      }
    end

    def build_quantities(job, job_loads, delivery=nil)
      if job_loads
        job_loads.collect{ |current_load|
          associated_quantity = job.quantities.find{ |quantity| quantity.unit && quantity.unit.id == current_load[:unit]} if job
          {
            unit: current_load[:unit],
            label: current_load[:label],
            value: associated_quantity && associated_quantity.value && (delivery.nil? ? 1 : -1) * associated_quantity.value,
            setup_value: current_load[:counting] ? associated_quantity && associated_quantity.setup_value : nil,
            current_load: current_load[:current_load]
          }.delete_if{ |k,v| !v }.compact
        }
      else
        job.quantities.collect{ |quantity|
          if quantity.unit
            {
              unit: quantity.unit.id,
              label: quantity.unit.label,
              value: quantity && quantity.value && (delivery.nil? ? 1 : -1) * quantity.value,
              setup_value: quantity.unit.counting ? quantity.setup_value : 0
            }
          end
        }.compact
      end
    end

    def build_rest(rest, day_index)
      {
        duration: rest.duration,
        timewindows: build_timewindows(rest, day_index)
      }
    end

    def build_detail(job, activity, point, day_index, job_load, vehicle, delivery=nil)
      {
        lat: point && point.location && point.location.lat,
        lon: point && point.location && point.location.lon,
        skills: job && job.skills ,
        setup_duration: activity && activity.setup_duration,
        duration: activity && activity.duration,
        additional_value: activity && activity.additional_value,
        timewindows: activity && build_timewindows(activity, day_index),
        quantities: build_quantities(job, job_load, delivery),
        router_mode: vehicle ? vehicle.router_mode : nil,
        speed_multiplier: vehicle ? vehicle.speed_multiplier : nil
      }.delete_if{ |k,v| !v }.compact
    end

    def check_services_compatible_days(vrp, vehicle, service)
      if (vrp.schedule_range_indices || vrp.schedule_range_date) && (service.minimum_lapse || service.maximum_lapse)
        (vehicle.global_day_index >= service[:first_possible_day] && vehicle.global_day_index <= service[:last_possible_day]) ? true : false
      else
        true
      end
    end

    def parse_output(vrp, services, points, matrix_indices, cost, iterations, output)
      if vrp.vehicles.size == 0 || (vrp.services.nil? || vrp.services.size == 0) && (vrp.shipments.nil? || vrp.shipments.size == 0)
        empty_result = {
          solvers: ['ortools'],
          cost: 0,
          iterations: 0,
          routes: [],
          unassigned: (vrp.services.collect{ |service|
            {
              service_id: "#{service.id}",
              type: service.type.to_s,
              point_id: service.activity.point_id,
              detail: build_detail(service, service.activity, service.activity.point, nil, nil, nil)
            }
          }) + (vrp.shipments.collect{ |shipment|
            [{
              shipment_id: "#{shipment.id}",
              type: 'pickup',
              point_id: shipment.pickup.point_id,
              detail: build_detail(shipment, shipment.pickup, shipment.pickup.point, nil, nil, nil)
            }] << {
              shipment_id: "#{shipment.id}",
              type: 'delivery',
              point_id: shipment.delivery.point_id,
              detail: build_detail(shipment, shipment.delivery, shipment.delivery.point, nil, nil, nil, true)
            }
          }).flatten + (vrp.rests.collect{ |rest|
            {
              rest_id: rest.id,
              detail: build_rest(rest, nil)
            }
          })
        }
        return empty_result
      end

      content = OrtoolsResult::Result.decode(output.read)
      output.rewind

      return @previous_result if content['routes'].empty? && @previous_result
      collected_indices = []
      collected_rests_indices = []
      {
        cost: content['cost'] || 0,
        solvers: ['ortools'],
        iterations: content['iterations'] || 0,
        routes: content['routes'].each_with_index.collect{ |route, index|
          vehicle = vrp.vehicles[index]
          previous_index = nil
          load_status = vrp.units.collect{ |unit|
            {
              unit: unit.id,
              label: unit.label,
              current_load: 0
            }
          }
          route_start = vehicle.timewindow && vehicle.timewindow[:start] ? vehicle.timewindow[:start] : 0
          earliest_start = route_start
          {
          vehicle_id: vehicle.id,
          activities: route['activities'].collect{ |activity|
            current_index = activity['index'] || 0
            activity_loads = load_status.collect.with_index{ |load_quantity, index|
              unit = vrp.units.find{ |unit| unit.id == load_quantity[:unit] }
              {
                unit: unit.id,
                label: unit.label,
                current_load: (activity['quantities'][index] || 0).round(2),
                counting: unit.counting
              }
            }
            earliest_start = activity['start_time'] || 0
            if activity['type'] == 'start'
              load_status = build_quantities(nil, activity_loads)
              if  vehicle.start_point
                previous_index = points[vehicle.start_point.id].matrix_index
                {
                  point_id: vehicle.start_point.id,
                  begin_time: earliest_start,
                  detail: build_detail(nil, nil, vehicle.start_point, nil, activity_loads, vehicle)
                }.delete_if{ |k,v| !v }
              end
            elsif activity['type'] == 'end'  && vehicle.end_point
              vehicle.end_point && {
                point_id: vehicle.end_point.id,
                begin_time: earliest_start,
                detail: vehicle.end_point.location ? {
                  lat: vehicle.end_point.location.lat,
                  lon: vehicle.end_point.location.lon,
                  quantities: activity_loads.collect{ |current_load|
                    {
                      unit: current_load[:unit],
                      value: current_load[:current_load]
                    }
                  }
                } : nil
              }.delete_if{ |k,v| !v }
            elsif activity['type'] == 'service'
              collected_indices << current_index
              if current_index < vrp.services.size
                point_index = services[current_index].matrix_index
                point = vrp.points[point_index]
                service = vrp.services[current_index]
                travel_time = (previous_index && point_index && vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:time] ? vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:time][previous_index][point_index] : 0)
                travel_value = (previous_index && point_index && vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:value] ? vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:value][previous_index][point_index] : 0)
                travel_distance = (previous_index && point_index && vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:distance] ? vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:distance][previous_index][point_index] : 0)
                current_activity = {
                  service_id: service.id,
                  point_id: point ? point.id : nil,
                  travel_time: travel_time,
                  travel_value: travel_value,
                  travel_distance: travel_distance,
                  begin_time: earliest_start,
                  departure_time: earliest_start + (service.activity ? service.activity[:duration].to_i : service.activities[activity['alternative']][:duration].to_i),
                  detail: build_detail(service, service.activity, point, vehicle.global_day_index ? vehicle.global_day_index%7 : nil, activity_loads, vehicle),
                  alternative: service.activities ? activity['alternative'] : nil
                }.delete_if{ |k,v| !v }
                previous_index = point_index
                current_activity
              else
                shipment_index = ((current_index - vrp.services.size)/2).to_i
                shipment_activity = (current_index - vrp.services.size)%2
                shipment = vrp.shipments[shipment_index]
                point_index = services[current_index].matrix_index
                point = vrp.points[point_index]
                earliest_start = activity['start_time'] || 0
                travel_time = (previous_index && point_index && vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:time] ? vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:time][previous_index][point_index] : 0)
                travel_value = (previous_index && point_index && vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:value] ? vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:value][previous_index][point_index] : 0)
                travel_distance = (previous_index && point_index && vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:distance] ? vrp.matrices.find{ |matrix| matrix.id == vehicle.matrix_id }[:distance][previous_index][point_index] : 0)
                current_activity = {
                  pickup_shipment_id: shipment_activity == 0 && shipment.id,
                  delivery_shipment_id: shipment_activity == 1 && shipment.id,
                  point_id: point.id,
                  travel_time: travel_time,
                  travel_value: travel_value,
                  travel_distance: travel_distance,
                  begin_time: earliest_start,
                  departure_time: earliest_start + (shipment_activity == 0 ? vrp.shipments[shipment_index].pickup[:duration].to_i : vrp.shipments[shipment_index].delivery[:duration].to_i ),
                  detail: build_detail(shipment, shipment_activity == 0 ? shipment.pickup : shipment.delivery, point, vehicle.global_day_index ? vehicle.global_day_index%7 : nil, activity_loads, vehicle, shipment_activity == 0 ? nil : true)
                }.delete_if{ |k,v| !v }
                earliest_start += shipment_activity == 0 ? vrp.shipments[shipment_index].pickup[:duration].to_i : vrp.shipments[shipment_index].delivery[:duration].to_i
                previous_index = point_index
                current_activity
              end
            elsif activity['type'] == 'break'
              collected_rests_indices << current_index
              vehicle_rest = vrp.vehicles.collect{ |vehicle| vehicle.rests }.flatten[current_index]
              earliest_start = vehicle_rest[:timewindows].nil? ? earliest_start : closest_rest_start(vehicle_rest[:timewindows], earliest_start)
              current_rest = {
                rest_id: vehicle_rest.id,
                begin_time: earliest_start,
                departure_time: earliest_start + vehicle_rest[:duration],
                detail: build_rest(vehicle_rest, vehicle.global_day_index ? vehicle.global_day_index%7 : nil)
              }
              earliest_start += vehicle_rest[:duration]
              current_rest
            else
              nil
            end
          }.compact,
          initial_loads: load_status.collect{ |unit|
            {
              unit: unit[:unit],
              label: unit[:label],
              value: unit[:current_load]
            }
          }
        }},
        unassigned: (vrp.services.collect(&:id) - collected_indices.collect{ |index| index < vrp.services.size && vrp.services[index].id }).collect{ |service_id|
          service = vrp.services.find{ |service| service.id == service_id }
          {
            service_id: service_id,
            type: service.type.to_s,
            point_id: service.activity ? service.activity.point_id : service.activities.collect{ |activity| activity[:point_id] },
            detail: service.activity ? build_detail(service, service.activity, service.activity.point, nil, nil, nil) : {activities: service.activities}
          }
        } + (vrp.shipments.collect(&:id) - collected_indices.collect{ |index| index >= vrp.services.size && ((index - vrp.services.size)/2).to_i < vrp.shipments.size && vrp.shipments[((index - vrp.services.size)/2).to_i].id }.uniq).collect{ |shipment_id|
          shipment = vrp.shipments.find{ |shipment| shipment.id == shipment_id }
          [{
            shipment_id: "#{shipment_id}",
            type: 'pickup',
            point_id: shipment.pickup.point_id,
            detail: build_detail(shipment, shipment.pickup, shipment.pickup.point, nil, nil, nil)
          }, {
            shipment_id: "#{shipment_id}",
            type: 'delivery',
            point_id: shipment.delivery.point_id,
            detail: build_detail(shipment, shipment.delivery, shipment.delivery.point, nil, nil, nil, true)
          }]
        }.flatten + (vrp.vehicles.collect{ |vehicle| vehicle.rests.collect(&:id) }.flatten - collected_rests_indices.collect{ |index| index < vrp.rests.size && vrp.rests[index].id }).collect{ |rest_id|
          rest = vrp.rests.find{ |rest| rest.id == rest_id }
          {
            rest_id: rest.id,
            detail: build_rest(rest, nil)
          }
        }
      }
    end

    def run_ortools(problem, vrp, services, points, matrix_indices, thread_proc = nil, &block)
      if vrp.vehicles.size == 0 || (vrp.services.nil? || vrp.services.size == 0) && (vrp.shipments.nil? || vrp.shipments.size == 0)
        return [0, 0, @previous_result = parse_output(vrp, services, points, matrix_indices, 0, 0, nil)]
      end
      input = Tempfile.new('optimize-or-tools-input', tmpdir=@tmp_dir)
      input.write(OrtoolsVrp::Problem.encode(problem))
      input.close

      output = Tempfile.new('optimize-or-tools-output', tmpdir=@tmp_dir)

      correspondant = { 'path_cheapest_arc' => 0, 'global_cheapest_arc' => 1, 'local_cheapest_insertion' => 2, 'savings' => 3, 'parallel_cheapest_insertion' => 4, 'first_unbound' => 5, 'christofides' => 6}
      raise StandardError.new('Unconsistent first solution strategy used internally') if vrp.preprocessing_first_solution_strategy && correspondant[vrp.preprocessing_first_solution_strategy.first].nil?
      cmd = [
        "#{@exec_ortools} ",
        (vrp.resolution_duration || @optimize_time) && '-time_limit_in_ms ' + (vrp.resolution_duration || @optimize_time).to_s,
        vrp.preprocessing_prefer_short_segment ? '-nearby' : nil,
        (vrp.resolution_evaluate_only ? nil : (vrp.preprocessing_neighbourhood_size ? "-neighbourhood #{vrp.preprocessing_neighbourhood_size}" : nil)),
        (vrp.resolution_iterations_without_improvment || @iterations_without_improvment) && '-no_solution_improvement_limit ' + (vrp.resolution_iterations_without_improvment || @iterations_without_improvment).to_s,
        (vrp.resolution_minimum_duration || vrp.resolution_initial_time_out) && '-minimum_duration ' + (vrp.resolution_minimum_duration || vrp.resolution_initial_time_out).to_s,
        (vrp.resolution_time_out_multiplier || @time_out_multiplier) && '-time_out_multiplier ' + (vrp.resolution_time_out_multiplier || @time_out_multiplier).to_s,
        vrp.resolution_vehicle_limit ? "-vehicle_limit #{vrp.resolution_vehicle_limit}" : nil,
        vrp.resolution_solver_parameter ? "-solver_parameter #{vrp.resolution_solver_parameter}" : nil,
        vrp.preprocessing_first_solution_strategy ? "-solver_parameter #{correspondant[vrp.preprocessing_first_solution_strategy.first]}" : nil,
        vrp.resolution_evaluate_only || vrp.resolution_batch_heuristic ? '-only_first_solution': nil,
        vrp.restitution_intermediate_solutions ? "-intermediate_solutions" : nil,
        "-instance_file '#{input.path}'",
        "-solution_file '#{output.path}'"].compact.join(' ')
      puts (@job ? @job + ' - ' : '') + cmd
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

      if thread_proc
        thread_proc.call(childs)
      end

      out = ''
      iterations = 0
      cost = nil
      time = 0.0
      # read of stdout_and_stderr stops at the end of process
      stdout_and_stderr.each_line { |line|
        puts (@job ? @job + ' - ' : '') + line
        out = out + line
        r = /^Iteration : ([0-9]+)/.match(line)
        r && (iterations = Integer(r[1]))
        s = / Cost : ([0-9.eE+]+)/.match(line)
        s && (cost = Integer(s[1]))
        t = / Time : ([0-9.eE+]+)/.match(line)
        t && (time = t[1].to_f)
        @previous_result = parse_output(vrp, services, points, matrix_indices, cost, iterations, output)
        if block && r && s && t && vrp.restitution_intermediate_solutions
          block.call(self, iterations, nil, nil, cost, t, @previous_result)
        end
      }

      result = out.split("\n")[-1]
      if @thread.value == 0
        if result == 'No solution found...'
          nil
        else
          cost = if result.include?('Cost : ')
            result.split(' ')[-4].to_i
          end
          iterations = if result.include?('Final Iteration : ')
            result.split(' ')[3].to_i
          end
          time = if result.include?('Time : ')
            result.split(' ')[-1].to_f
          end
          @previous_result = parse_output(vrp, services, points, matrix_indices, cost, iterations, output)
          if block
            block.call(self, iterations, nil, nil, cost, time, @previous_result)
          end
          [cost, iterations, @previous_result]
        end
      elsif @thread.value == 9
        out = "Job killed"
        puts (@job ? @job + ' - ' : '') + out # Keep trace in worker
        if cost && !result.include?('Iteration : ')
          [cost, iterations, @previous_result = parse_output(vrp, services, points, matrix_indices, cost, iterations, output)]
        else
          out
        end
      else
        raise RuntimeError.new(result) unless vrp.restitution_allow_empty_result
      end
    ensure
      input && input.unlink
      output && output.unlink
    end
  end
end
