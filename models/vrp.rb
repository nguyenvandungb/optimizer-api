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
require './models/base'


module Models
  class Vrp < Base
    field :preprocessing_cluster_threshold, default: nil
    field :preporcessing_prefer_short_segment, default: false
    field :resolution_duration, default: nil
    validates_numericality_of :preprocessing_cluster_threshold
    validates_numericality_of :resolution_duration

    fields :matrix_time, :matrix_distance

    has_many :points, class_name: 'Models::Point'
    has_many :services, class_name: 'Models::Service'
    has_many :shipments, class_name: 'Models::Shipment'
    has_many :rests, class_name: 'Models::Rest'
    has_many :vehicles, class_name: 'Models::Vehicle', inverse_of: :vrp
    has_many :units, class_name: 'Models::Units'

    def initialize(hash)
      super(hash)
#      hash[:points] && hash[:points].each{ |point| self.points << Point.create(point) }
#      hash[:services] && hash[:services].each{ |service| self.services << Service.create(service) }
#      hash[:shipments] && hash[:shipments].each{ |shipment| self.shipment << Shipment.create(shipment) }
#      hash[:rests] && hash[:rests].each{ |rest| self.rests << Rest.create(rest) }
#      hash[:vehicles] && hash[:vehicles].each{ |vehicle| self.vehicles << Vehicle.create(vehicle) }
    end

    def matrices=(matrices)
      self.matrix_time = matrices[:time]
      self.matrix_distance = matrices[:distance]
    end

    def resolution=(resolution)
      self.resolution_duration = resolution[:duration]
    end

    def points=(vs)
      self.attributes[:points] = []
      vs && vs.each{ |point| self.attributes[:points] << Point.create(point.merge(vrp: self)) }
    end

    def points
      self.attributes[:points] || []
    end

    def services=(vs)
      self.attributes[:services] = []
      vs && vs.each{ |service| self.attributes[:services] << Service.create(service.merge(vrp: self)) }
    end

    def services
      self.attributes[:services] || []
    end

    def shipments=(vs)
      self.attributes[:shipments] = []
      vs && vs.each{ |shipment| self.attributes[:shipments] << Shipment.create(shipment.merge(vrp: self)) }
    end

    def shipments
      self.attributes[:shipments] || []
    end

    def rests=(vs)
      self.attributes[:rests] = []
      vs && vs.each{ |rest| self.attributes[:rests] << Rest.create(rest.merge(vrp: self)) }
    end

    def rests
      self.attributes[:rests] || []
    end

    def vehicles=(vs)
     self.attributes[:vehicles] = []
      vs && vs.each{ |vehicle| self.attributes[:vehicles] << Vehicle.create(vehicle.merge(vrp: self)) }
    end

    def vehicles
      self.attributes[:vehicles] #|| []
    end

    def units=(vs)
     self.attributes[:units] = []
      vs && vs.each{ |vehicle| self.attributes[:units] << Vehicle.create(vehicle.merge(vrp: self)) }
    end

    def units
      self.attributes[:units] || []
    end
  end
end
