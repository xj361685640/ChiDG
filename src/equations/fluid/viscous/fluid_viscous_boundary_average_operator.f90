module fluid_viscous_boundary_average_operator
    use mod_kinds,              only: rk,ik
    use mod_constants,          only: ONE, TWO, HALF, ME, NEIGHBOR

    use type_operator,          only: operator_t
    use type_chidg_worker,      only: chidg_worker_t
    use type_properties,        only: properties_t
    use DNAD_D
    implicit none

    private



    !> Implementation of the Euler boundary average flux
    !!
    !!  - At a boundary interface, the solution states Q- and Q+ exists on opposite 
    !!    sides of the boundary. The average flux is computed as Favg = 1/2(F(Q-) + F(Q+))
    !!
    !!  @author Nathan A. Wukie
    !!  @date   1/28/2016
    !!
    !--------------------------------------------------------------------------------
    type, extends(operator_t), public :: fluid_viscous_boundary_average_operator_t

    contains

        procedure   :: init
        procedure   :: compute

    end type fluid_viscous_boundary_average_operator_t
    !********************************************************************************










contains



    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   8/29/2016
    !!
    !--------------------------------------------------------------------------------
    subroutine init(self)
        class(fluid_viscous_boundary_average_operator_t),   intent(inout) :: self
        
        !
        ! Set operator name
        !
        call self%set_name("Fluid Viscous Boundary Average Operator")

        !
        ! Set operator type
        !
        call self%set_operator_type("Boundary Diffusive Flux")

        !
        ! Set operator equations
        !
        call self%set_equation("Density"   )
        call self%set_equation("X-Momentum")
        call self%set_equation("Y-Momentum")
        call self%set_equation("Z-Momentum")
        call self%set_equation("Energy"    )

    end subroutine init
    !********************************************************************************



    !>  Boundary Flux routine for Euler
    !!
    !!  @author Nathan A. Wukie
    !!  @date   1/28/2016
    !!
    !!-------------------------------------------------------------------------------------
    subroutine compute(self,worker,prop)
        class(fluid_viscous_boundary_average_operator_t),   intent(inout)   :: self
        type(chidg_worker_t),                       intent(inout)   :: worker
        class(properties_t),                        intent(inout)   :: prop

        ! Equation indices
        integer(ik)     :: irho, irhou, irhov, irhow, irhoE


        ! Storage at quadrature nodes
        type(AD_D), allocatable, dimension(:) ::                                    &
            rho_m, rhou_m, rhov_m, rhow_m, rhoE_m,                                  &
            rho_p, rhou_p, rhov_p, rhow_p, rhoE_p,                                  &
            p_m, T_m, u_m, v_m, w_m, invrho_m, gam_m, mu_m, lamda_m,                &
            p_p, T_p, u_p, v_p, w_p, invrho_p, gam_p, mu_p, lamda_p,                &
            drho_dx_m, drhou_dx_m, drhov_dx_m, drhow_dx_m, drhoE_dx_m,              &
            drho_dy_m, drhou_dy_m, drhov_dy_m, drhow_dy_m, drhoE_dy_m,              &
            drho_dz_m, drhou_dz_m, drhov_dz_m, drhow_dz_m, drhoE_dz_m,              &
            drho_dx_p, drhou_dx_p, drhov_dx_p, drhow_dx_p, drhoE_dx_p,              &
            drho_dy_p, drhou_dy_p, drhov_dy_p, drhow_dy_p, drhoE_dy_p,              &
            drho_dz_p, drhou_dz_p, drhov_dz_p, drhow_dz_p, drhoE_dz_p,              &
            du_dx_m,   dv_dx_m,    dw_dx_m,    dT_dx_m,                             &
            du_dy_m,   dv_dy_m,    dw_dy_m,    dT_dy_m,                             &
            du_dz_m,   dv_dz_m,    dw_dz_m,    dT_dz_m,                             &
            du_dx_p,   dv_dx_p,    dw_dx_p,    dT_dx_p,                             &
            du_dy_p,   dv_dy_p,    dw_dy_p,    dT_dy_p,                             &
            du_dz_p,   dv_dz_p,    dw_dz_p,    dT_dz_p,                             &
            du_drho_m, du_drhou_m, dv_drho_m,  dv_drhov_m, dw_drho_m, dw_drhow_m,   &
            du_drho_p, du_drhou_p, dv_drho_p,  dv_drhov_p, dw_drho_p, dw_drhow_p,   &
            dT_drho_m, dT_drhou_m, dT_drhov_m, dT_drhow_m, dT_drhoE_m,              &
            dT_drho_p, dT_drhou_p, dT_drhov_p, dT_drhow_p, dT_drhoE_p,              &
            dp_drho_m, dp_drhou_m, dp_drhov_m, dp_drhow_m, dp_drhoE_m,              &
            dp_drho_p, dp_drhou_p, dp_drhov_p, dp_drhow_p, dp_drhoE_p,              &
            dke_drho_m, dke_drhou_m, dke_drhov_m, dke_drhow_m,                      &
            dke_drho_p, dke_drhou_p, dke_drhov_p, dke_drhow_p,                      &
            tau_xx_m, tau_yy_m, tau_zz_m, tau_xy_m, tau_xz_m, tau_yz_m,             &
            tau_xx_p, tau_yy_p, tau_zz_p, tau_xy_p, tau_xz_p, tau_yz_p,             &
            flux_x_m, flux_y_m, flux_z_m,                                           &
            flux_x_p, flux_y_p, flux_z_p,                                           &
            flux_x, flux_y, flux_z, integrand


        real(rk), allocatable, dimension(:) ::      &
            normx, normy, normz


        real(rk) :: const

        irho  = prop%get_equation_index("Density"   )
        irhou = prop%get_equation_index("X-Momentum")
        irhov = prop%get_equation_index("Y-Momentum")
        irhow = prop%get_equation_index("Z-Momentum")
        irhoE = prop%get_equation_index("Energy"    )



        !
        ! Interpolate solution to quadrature nodes
        !
        rho_m  = worker%get_face_variable(irho, 'value', ME)
        rho_p  = worker%get_face_variable(irho, 'value', NEIGHBOR)

        rhou_m = worker%get_face_variable(irhou, 'value', ME)
        rhou_p = worker%get_face_variable(irhou, 'value', NEIGHBOR)

        rhov_m = worker%get_face_variable(irhov, 'value', ME)
        rhov_p = worker%get_face_variable(irhov, 'value', NEIGHBOR)

        rhow_m = worker%get_face_variable(irhow, 'value', ME)
        rhow_p = worker%get_face_variable(irhow, 'value', NEIGHBOR)

        rhoE_m = worker%get_face_variable(irhoE, 'value', ME)
        rhoE_p = worker%get_face_variable(irhoE, 'value', NEIGHBOR)


        !
        ! Interpolate gradient to quadrature nodes
        !
        drho_dx_m  = worker%get_face_variable(irho,  'ddx+lift', ME)
        drho_dy_m  = worker%get_face_variable(irho,  'ddy+lift', ME)
        drho_dz_m  = worker%get_face_variable(irho,  'ddz+lift', ME)
        drho_dx_p  = worker%get_face_variable(irho,  'ddx+lift', NEIGHBOR)
        drho_dy_p  = worker%get_face_variable(irho,  'ddy+lift', NEIGHBOR)
        drho_dz_p  = worker%get_face_variable(irho,  'ddz+lift', NEIGHBOR)

        drhou_dx_m = worker%get_face_variable(irhou, 'ddx+lift', ME)
        drhou_dy_m = worker%get_face_variable(irhou, 'ddy+lift', ME)
        drhou_dz_m = worker%get_face_variable(irhou, 'ddz+lift', ME)
        drhou_dx_p = worker%get_face_variable(irhou, 'ddx+lift', NEIGHBOR)
        drhou_dy_p = worker%get_face_variable(irhou, 'ddy+lift', NEIGHBOR)
        drhou_dz_p = worker%get_face_variable(irhou, 'ddz+lift', NEIGHBOR)

        drhov_dx_m = worker%get_face_variable(irhov, 'ddx+lift', ME)
        drhov_dy_m = worker%get_face_variable(irhov, 'ddy+lift', ME)
        drhov_dz_m = worker%get_face_variable(irhov, 'ddz+lift', ME)
        drhov_dx_p = worker%get_face_variable(irhov, 'ddx+lift', NEIGHBOR)
        drhov_dy_p = worker%get_face_variable(irhov, 'ddy+lift', NEIGHBOR)
        drhov_dz_p = worker%get_face_variable(irhov, 'ddz+lift', NEIGHBOR)

        drhow_dx_m = worker%get_face_variable(irhow, 'ddx+lift', ME)
        drhow_dy_m = worker%get_face_variable(irhow, 'ddy+lift', ME)
        drhow_dz_m = worker%get_face_variable(irhow, 'ddz+lift', ME)
        drhow_dx_p = worker%get_face_variable(irhow, 'ddx+lift', NEIGHBOR)
        drhow_dy_p = worker%get_face_variable(irhow, 'ddy+lift', NEIGHBOR)
        drhow_dz_p = worker%get_face_variable(irhow, 'ddz+lift', NEIGHBOR)

        drhoE_dx_m = worker%get_face_variable(irhoE, 'ddx+lift', ME)
        drhoE_dy_m = worker%get_face_variable(irhoE, 'ddy+lift', ME)
        drhoE_dz_m = worker%get_face_variable(irhoE, 'ddz+lift', ME)
        drhoE_dx_p = worker%get_face_variable(irhoE, 'ddx+lift', NEIGHBOR)
        drhoE_dy_p = worker%get_face_variable(irhoE, 'ddy+lift', NEIGHBOR)
        drhoE_dz_p = worker%get_face_variable(irhoE, 'ddz+lift', NEIGHBOR)


        invrho_m = ONE/rho_m
        invrho_p = ONE/rho_p


        !
        ! Get normal vector
        !
        normx = worker%normal(1)
        normy = worker%normal(2)
        normz = worker%normal(3)



        !
        ! Compute pressure and total enthalpy
        !
        p_m = prop%fluid%compute_pressure(rho_m,rhou_m,rhov_m,rhow_m,rhoE_m)
        p_p = prop%fluid%compute_pressure(rho_p,rhou_p,rhov_p,rhow_p,rhoE_p)

        gam_m = prop%fluid%compute_gamma(rho_m,rhou_m,rhov_m,rhow_m,rhoE_m)
        gam_p = prop%fluid%compute_gamma(rho_p,rhou_p,rhov_p,rhow_p,rhoE_p)


        !
        ! Compute velocities
        !
        u_m = rhou_m/rho_m
        v_m = rhov_m/rho_m
        w_m = rhow_m/rho_m

        u_p = rhou_p/rho_p
        v_p = rhov_p/rho_p
        w_p = rhow_p/rho_p



        !
        ! Compute velocity jacobians
        !
        du_drho_m  = -invrho_m*invrho_m*rhou_m
        dv_drho_m  = -invrho_m*invrho_m*rhov_m
        dw_drho_m  = -invrho_m*invrho_m*rhow_m
        du_drho_p  = -invrho_p*invrho_p*rhou_p
        dv_drho_p  = -invrho_p*invrho_p*rhov_p
        dw_drho_p  = -invrho_p*invrho_p*rhow_p

        du_drhou_m =  invrho_m
        dv_drhov_m =  invrho_m
        dw_drhow_m =  invrho_m
        du_drhou_p =  invrho_p
        dv_drhov_p =  invrho_p
        dw_drhow_p =  invrho_p








        !
        ! Compute Kinetic Energy Jacobians
        !
        dke_drho_m  = -HALF*(u_m*u_m + v_m*v_m + w_m*w_m)
        dke_drhou_m = u_m
        dke_drhov_m = v_m
        dke_drhow_m = w_m

        dke_drho_p  = -HALF*(u_p*u_p + v_p*v_p + w_p*w_p)
        dke_drhou_p = u_p
        dke_drhov_p = v_p
        dke_drhow_p = w_p




        !
        ! Compute Pressure Jacobians
        !
        dp_drho_m  = -(gam_m-ONE)*dke_drho_m
        dp_drhou_m = -(gam_m-ONE)*dke_drhou_m
        dp_drhov_m = -(gam_m-ONE)*dke_drhov_m
        dp_drhow_m = -(gam_m-ONE)*dke_drhow_m
        dp_drhoE_m =  (gam_m-ONE)   ! No negative sign

        dp_drho_p  = -(gam_p-ONE)*dke_drho_p
        dp_drhou_p = -(gam_p-ONE)*dke_drhou_p
        dp_drhov_p = -(gam_p-ONE)*dke_drhov_p
        dp_drhow_p = -(gam_p-ONE)*dke_drhow_p
        dp_drhoE_p =  (gam_p-ONE)   ! No negative sign


        !
        ! Compute Temperature Jacobians
        !
        const = ONE/287.06_rk
        dT_drho_m  = const*invrho_m*dp_drho_m  -  const*invrho_m*invrho_m*p_m
        dT_drhou_m = const*invrho_m*dp_drhou_m
        dT_drhov_m = const*invrho_m*dp_drhov_m
        dT_drhow_m = const*invrho_m*dp_drhow_m
        dT_drhoE_m = const*invrho_m*dp_drhoE_m

        dT_drho_p  = const*invrho_p*dp_drho_p  -  const*invrho_p*invrho_p*p_p
        dT_drhou_p = const*invrho_p*dp_drhou_p
        dT_drhov_p = const*invrho_p*dp_drhov_p
        dT_drhow_p = const*invrho_p*dp_drhow_p
        dT_drhoE_p = const*invrho_p*dp_drhoE_p


        !
        ! Compute velocity gradients
        !
        du_dx_m = du_drho_m*drho_dx_m  +  du_drhou_m*drhou_dx_m
        du_dy_m = du_drho_m*drho_dy_m  +  du_drhou_m*drhou_dy_m
        du_dz_m = du_drho_m*drho_dz_m  +  du_drhou_m*drhou_dz_m

        dv_dx_m = dv_drho_m*drho_dx_m  +  dv_drhov_m*drhov_dx_m
        dv_dy_m = dv_drho_m*drho_dy_m  +  dv_drhov_m*drhov_dy_m
        dv_dz_m = dv_drho_m*drho_dz_m  +  dv_drhov_m*drhov_dz_m

        dw_dx_m = dw_drho_m*drho_dx_m  +  dw_drhow_m*drhow_dx_m
        dw_dy_m = dw_drho_m*drho_dy_m  +  dw_drhow_m*drhow_dy_m
        dw_dz_m = dw_drho_m*drho_dz_m  +  dw_drhow_m*drhow_dz_m


        du_dx_p = du_drho_p*drho_dx_p  +  du_drhou_p*drhou_dx_p
        du_dy_p = du_drho_p*drho_dy_p  +  du_drhou_p*drhou_dy_p
        du_dz_p = du_drho_p*drho_dz_p  +  du_drhou_p*drhou_dz_p

        dv_dx_p = dv_drho_p*drho_dx_p  +  dv_drhov_p*drhov_dx_p
        dv_dy_p = dv_drho_p*drho_dy_p  +  dv_drhov_p*drhov_dy_p
        dv_dz_p = dv_drho_p*drho_dz_p  +  dv_drhov_p*drhov_dz_p

        dw_dx_p = dw_drho_p*drho_dx_p  +  dw_drhow_p*drhow_dx_p
        dw_dy_p = dw_drho_p*drho_dy_p  +  dw_drhow_p*drhow_dy_p
        dw_dz_p = dw_drho_p*drho_dz_p  +  dw_drhow_p*drhow_dz_p



        !
        ! Compute temperature
        !
        T_m = prop%fluid%compute_temperature(rho_m,rhou_m,rhov_m,rhow_m,rhoE_m)
        T_p = prop%fluid%compute_temperature(rho_p,rhou_p,rhov_p,rhow_p,rhoE_p)


        !
        ! Compute dynamic viscosity, second coefficient of viscosity
        !
        mu_m    = prop%fluid%compute_viscosity_dynamic(T_m)
        mu_p    = prop%fluid%compute_viscosity_dynamic(T_p)

        lamda_m = prop%fluid%compute_viscosity_second(mu_m,T_m)
        lamda_p = prop%fluid%compute_viscosity_second(mu_p,T_p)




        !
        ! Compute temperature gradient
        !
        dT_dx_m = dT_drho_m*drho_dx_m + dT_drhou_m*drhou_dx_m + dT_drhov_m*drhov_dx_m + dT_drhow_m*drhow_dx_m + dT_drhoE_m*drhoE_dx_m
        dT_dy_m = dT_drho_m*drho_dy_m + dT_drhou_m*drhou_dy_m + dT_drhov_m*drhov_dy_m + dT_drhow_m*drhow_dy_m + dT_drhoE_m*drhoE_dy_m
        dT_dz_m = dT_drho_m*drho_dz_m + dT_drhou_m*drhou_dz_m + dT_drhov_m*drhov_dz_m + dT_drhow_m*drhow_dz_m + dT_drhoE_m*drhoE_dz_m

        dT_dx_p = dT_drho_p*drho_dx_p + dT_drhou_p*drhou_dx_p + dT_drhov_p*drhov_dx_p + dT_drhow_p*drhow_dx_p + dT_drhoE_p*drhoE_dx_p
        dT_dy_p = dT_drho_p*drho_dy_p + dT_drhou_p*drhou_dy_p + dT_drhov_p*drhov_dy_p + dT_drhow_p*drhow_dy_p + dT_drhoE_p*drhoE_dy_p
        dT_dz_p = dT_drho_p*drho_dz_p + dT_drhou_p*drhou_dz_p + dT_drhov_p*drhov_dz_p + dT_drhow_p*drhow_dz_p + dT_drhoE_p*drhoE_dz_p





        !
        ! Compute shear stress components
        !
        tau_xx_m = TWO*mu_m*du_dx_m  +  lamda_m*(du_dx_m + dv_dy_m + dw_dz_m)
        tau_yy_m = TWO*mu_m*dv_dy_m  +  lamda_m*(du_dx_m + dv_dy_m + dw_dz_m)
        tau_zz_m = TWO*mu_m*dw_dz_m  +  lamda_m*(du_dx_m + dv_dy_m + dw_dz_m)

        tau_xy_m = mu_m*(du_dy_m + dv_dx_m)
        tau_xz_m = mu_m*(du_dz_m + dw_dx_m)
        tau_yz_m = mu_m*(dw_dy_m + dv_dz_m)


        tau_xx_p = TWO*mu_p*du_dx_p  +  lamda_p*(du_dx_p + dv_dy_p + dw_dz_p)
        tau_yy_p = TWO*mu_p*dv_dy_p  +  lamda_p*(du_dx_p + dv_dy_p + dw_dz_p)
        tau_zz_p = TWO*mu_p*dw_dz_p  +  lamda_p*(du_dx_p + dv_dy_p + dw_dz_p)

        tau_xy_p = mu_p*(du_dy_p + dv_dx_p)
        tau_xz_p = mu_p*(du_dz_p + dw_dx_p)
        tau_yz_p = mu_p*(dw_dy_p + dv_dz_p)






        !================================
        !       MASS FLUX
        !================================


        !================================
        !       X-MOMENTUM FLUX
        !================================
        flux_x_m = -tau_xx_m
        flux_y_m = -tau_xy_m
        flux_z_m = -tau_xz_m

        flux_x_p = -tau_xx_p
        flux_y_p = -tau_xy_p
        flux_z_p = -tau_xz_p

        flux_x = (flux_x_m + flux_x_p)
        flux_y = (flux_y_m + flux_y_p)
        flux_z = (flux_z_m + flux_z_p)


        ! dot with normal vector
        integrand = HALF*(flux_x*normx + flux_y*normy + flux_z*normz)

        call worker%integrate_boundary(irhou, integrand)


        !================================
        !       Y-MOMENTUM FLUX
        !================================
        flux_x_m = -tau_xy_m
        flux_y_m = -tau_yy_m
        flux_z_m = -tau_yz_m

        flux_x_p = -tau_xy_p
        flux_y_p = -tau_yy_p
        flux_z_p = -tau_yz_p

        flux_x = (flux_x_m + flux_x_p)
        flux_y = (flux_y_m + flux_y_p)
        flux_z = (flux_z_m + flux_z_p)


        ! dot with normal vector
        integrand = HALF*(flux_x*normx + flux_y*normy + flux_z*normz)

        call worker%integrate_boundary(irhov, integrand)


        !================================
        !       Z-MOMENTUM FLUX
        !================================
!        flux_x_m = -tau_xz_m
!        flux_y_m = -tau_yz_m
!        flux_z_m = -tau_zz_m
!
!        flux_x_p = -tau_xz_p
!        flux_y_p = -tau_yz_p
!        flux_z_p = -tau_zz_p
!
!
!        flux_x = (flux_x_m + flux_x_p)
!        flux_y = (flux_y_m + flux_y_p)
!        flux_z = (flux_z_m + flux_z_p)
!
!
!        ! dot with normal vector
!        integrand = HALF*(flux_x*normx + flux_y*normy + flux_z*normz)
!
!!        print*, "boundary average z-momentum"
!!        print*, integrand(:)%x_ad_
!
!
!
!        call worker%integrate_boundary(irhow, integrand)


        !================================
        !          ENERGY FLUX
        !================================
        flux_x_m = -(1003._rk*mu_m/0.8_rk)*dT_dx_m  -  (u_m*tau_xx_m + v_m*tau_xy_m + w_m*tau_xz_m)
        flux_y_m = -(1003._rk*mu_m/0.8_rk)*dT_dy_m  -  (u_m*tau_xy_m + v_m*tau_yy_m + w_m*tau_yz_m)
        flux_z_m = -(1003._rk*mu_m/0.8_rk)*dT_dz_m  -  (u_m*tau_xz_m + v_m*tau_yz_m + w_m*tau_zz_m)

        flux_x_p = -(1003._rk*mu_p/0.8_rk)*dT_dx_p  -  (u_p*tau_xx_p + v_p*tau_xy_p + w_p*tau_xz_p)
        flux_y_p = -(1003._rk*mu_p/0.8_rk)*dT_dy_p  -  (u_p*tau_xy_p + v_p*tau_yy_p + w_p*tau_yz_p)
        flux_z_p = -(1003._rk*mu_p/0.8_rk)*dT_dz_p  -  (u_p*tau_xz_p + v_p*tau_yz_p + w_p*tau_zz_p)


        flux_x = (flux_x_m + flux_x_p)
        flux_y = (flux_y_m + flux_y_p)
        flux_z = (flux_z_m + flux_z_p)


        ! dot with normal vector
        integrand = HALF*(flux_x*normx + flux_y*normy + flux_z*normz)

        call worker%integrate_boundary(irhoE, integrand)


    end subroutine compute
    !*********************************************************************************************************












end module fluid_viscous_boundary_average_operator
