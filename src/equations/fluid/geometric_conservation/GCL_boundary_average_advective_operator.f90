module GCL_boundary_average_advective_operator
#include <messenger.h>
    use mod_kinds,                  only: rk,ik
    use mod_constants,              only: ZERO,ONE,TWO,HALF
    use type_operator,              only: operator_t
    use type_chidg_worker,          only: chidg_worker_t
    use type_properties,            only: properties_t
    use DNAD_D
    implicit none


    !>
    !!
    !!  @author Nathan A. Wukie
    !!
    !!
    !!
    !!
    !--------------------------------------------------------------------------------
    type, extends(operator_t), public :: GCL_boundary_average_advective_operator_t


    contains

        procedure   :: init
        procedure   :: compute

    end type GCL_boundary_average_advective_operator_t
    !********************************************************************************



contains


    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/29/2016
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(GCL_boundary_average_advective_operator_t),   intent(inout)  :: self

        ! Set operator name
        call self%set_name('Geometric Conservation Boundary Average Operator')

        ! Set operator type
        call self%set_operator_type('Boundary Advective Operator')

        ! Set operator equations
        call self%add_primary_field('g_bar')

    end subroutine init
    !********************************************************************************










    !> Compute the average advective boundary flux for scalar linear advection
    !!
    !!   @author Nathan A. Wukie
    !!
    !!   @param[in]      mesh    Mesh data
    !!   @param[inout]   sdata   Solver data. Solution, RHS, Linearization etc.
    !!   @param[in]      ielem   Element index
    !!   @param[in]      iface   Face index
    !!   @param[in]      iblk    Block index indicating the linearization direction
    !!
    !-----------------------------------------------------------------------------------------
    subroutine compute(self,worker,prop)
        class(GCL_boundary_average_advective_operator_t),   intent(inout)   :: self
        type(chidg_worker_t),                               intent(inout)   :: worker
        class(properties_t),                                intent(inout)   :: prop


        type(AD_D), allocatable, dimension(:)   ::  &
            g_bar,                                  &
            flux_1_m, flux_2_m, flux_3_m,           &
            flux_1_p, flux_2_p, flux_3_p            


        real(rk),   allocatable, dimension(:)       :: det_jacobian_grid_m, det_jacobian_grid_p
        real(rk),   allocatable, dimension(:,:)     :: grid_velocity
        real(rk),   allocatable, dimension(:,:,:)   :: inv_jacobian_grid_m, inv_jacobian_grid_p

       
        !
        ! Interpolate solution to quadrature nodes
        !
        g_bar = worker%get_field('g_bar', 'value', 'face interior')

        
        !
        ! Get model coefficients
        !
        grid_velocity       = worker%get_grid_velocity_face('face interior')
        det_jacobian_grid_m = worker%get_det_jacobian_grid_face('value','face interior')
        det_jacobian_grid_p = worker%get_det_jacobian_grid_face('value','face exterior')
        inv_jacobian_grid_m = worker%get_inv_jacobian_grid_face('face interior')
        inv_jacobian_grid_p = worker%get_inv_jacobian_grid_face('face exterior')


        !
        ! Compute boundary average flux
        !
        flux_1_m = g_bar  !just to initialize AD allocation
        flux_2_m = g_bar  !just to initialize AD allocation
        flux_3_m = g_bar  !just to initialize AD allocation
        flux_1_m = (inv_jacobian_grid_m(:,1,1)*grid_velocity(:,1) + inv_jacobian_grid_m(:,1,2)*grid_velocity(:,2) + inv_jacobian_grid_m(:,1,3)*grid_velocity(:,3))*det_jacobian_grid_m
        flux_2_m = (inv_jacobian_grid_m(:,2,1)*grid_velocity(:,1) + inv_jacobian_grid_m(:,2,2)*grid_velocity(:,2) + inv_jacobian_grid_m(:,2,3)*grid_velocity(:,3))*det_jacobian_grid_m
        flux_3_m = (inv_jacobian_grid_m(:,3,1)*grid_velocity(:,1) + inv_jacobian_grid_m(:,3,2)*grid_velocity(:,2) + inv_jacobian_grid_m(:,3,3)*grid_velocity(:,3))*det_jacobian_grid_m

        flux_1_p = g_bar  !just to initialize AD allocation
        flux_2_p = g_bar  !just to initialize AD allocation
        flux_3_p = g_bar  !just to initialize AD allocation
        flux_1_p = (inv_jacobian_grid_p(:,1,1)*grid_velocity(:,1) + inv_jacobian_grid_p(:,1,2)*grid_velocity(:,2) + inv_jacobian_grid_p(:,1,3)*grid_velocity(:,3))*det_jacobian_grid_p
        flux_2_p = (inv_jacobian_grid_p(:,2,1)*grid_velocity(:,1) + inv_jacobian_grid_p(:,2,2)*grid_velocity(:,2) + inv_jacobian_grid_p(:,2,3)*grid_velocity(:,3))*det_jacobian_grid_p
        flux_3_p = (inv_jacobian_grid_p(:,3,1)*grid_velocity(:,1) + inv_jacobian_grid_p(:,3,2)*grid_velocity(:,2) + inv_jacobian_grid_p(:,3,3)*grid_velocity(:,3))*det_jacobian_grid_p


        !
        ! Integrate flux
        !
        call worker%integrate_boundary_average('g_bar','Advection',             &
                                                flux_1_m, flux_2_m, flux_3_m,   &
                                                flux_1_p, flux_2_p, flux_3_p)


    end subroutine compute
    !**************************************************************************************************




end module GCL_boundary_average_advective_operator
